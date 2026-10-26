import Foundation
import AVFoundation
import Vision
import QuartzCore
import CoreGraphics

/// "Redness" (2R − G − B)/2 of one camera frame at full resolution, used for laser-dot detection.
struct RedFrame {
    let width: Int
    let height: Int
    let data: [UInt8]
    let time: CFTimeInterval
}

/// Detected target in normalised image coordinates (origin top-left, 0…1, portrait).
struct CatDetection {
    let rect: CGRect
    let confidence: Float
    let time: CFTimeInterval
}

enum CameraLens: String, CaseIterable, Identifiable, Codable {
    case ultraWide
    case standard
    case lidar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraWide: return "0,5×"
        case .standard: return "1×"
        case .lidar: return "1× + LiDAR"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .standard: return .builtInWideAngleCamera
        case .lidar: return .builtInLiDARDepthCamera
        }
    }

    var isAvailable: Bool {
        AVCaptureDevice.default(deviceType, for: .video, position: .back) != nil
    }
}

enum DetectTarget: String, CaseIterable, Identifiable {
    case cat
    case human
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cat: return "Kočka"
        case .human: return "Člověk (nohy)"
        }
    }
}

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published var lens: CameraLens
    @Published var isRunning = false
    @Published var authorized = true
    @Published var fps: Double = 0
    @Published var detectFps: Double = 0
    @Published var detection: CatDetection?
    @Published var lastDetectionConfidence: Float = 0
    @Published var errorText = ""
    /// width / height of the (portrait) video frames
    @Published var imageAspect: CGFloat = 9.0 / 16.0
    @Published var depthBackgroundReady = false
    @Published var depthLearning = false

    @Published var target: DetectTarget = DetectTarget(rawValue: UserDefaults.standard.string(forKey: "camera.target") ?? "") ?? .cat {
        didSet { UserDefaults.standard.set(target.rawValue, forKey: "camera.target") }
    }
    /// Minimum Vision confidence.
    @Published var minConfidence: Float = UserDefaults.standard.object(forKey: "camera.minConfidence") as? Float ?? 0.3 {
        didSet { UserDefaults.standard.set(minConfidence, forKey: "camera.minConfidence") }
    }
    /// LiDAR: minimum height above the floor (m) for something to count as an object.
    @Published var depthThreshold: Float = UserDefaults.standard.object(forKey: "camera.depthThreshold") as? Float ?? 0.05 {
        didSet { UserDefaults.standard.set(depthThreshold, forKey: "camera.depthThreshold") }
    }

    var usesDepth: Bool { lens == .lidar }

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private let visionQueue = DispatchQueue(label: "camera.vision")
    private let depthQueue = DispatchQueue(label: "camera.depth")
    private let output = AVCaptureVideoDataOutput()
    private let depthOutput = AVCaptureDepthDataOutput()
    private var input: AVCaptureDeviceInput?
    private var configured = false

    // video-queue state
    private var grabRequests: [(notBefore: CFTimeInterval, completion: (RedFrame) -> Void)] = []
    private let grabLock = NSLock()
    private var visionBusy = false
    private var lastVisionStart: CFTimeInterval = 0
    private var frameCount = 0
    private var detectCount = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var detectionEnabled = true
    private var lastAspect: CGFloat = 0
    private var visionTarget: DetectTarget = .cat
    private var visionMinConfidence: Float = 0.3

    // depth-queue state
    private let depth = DepthDetector()
    private var depthEnabled = false
    private var lastDepthProcess: CFTimeInterval = 0
    private var depthCount = 0
    private var depthWindowStart: CFTimeInterval = 0

    private lazy var animalRequest = VNRecognizeAnimalsRequest()
    private lazy var humanRequest: VNDetectHumanRectanglesRequest = {
        let r = VNDetectHumanRectanglesRequest()
        r.upperBodyOnly = false
        return r
    }()

    override init() {
        let saved = UserDefaults.standard.string(forKey: "camera.lens").flatMap(CameraLens.init(rawValue:))
        if let s = saved, s.isAvailable {
            lens = s
        } else {
            lens = CameraLens.ultraWide.isAvailable ? .ultraWide : .standard
        }
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async {
                    self.authorized = ok
                    if ok { self.startSession() }
                }
            }
        default:
            authorized = false
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setLens(_ newLens: CameraLens) {
        guard newLens.isAvailable, newLens != lens else { return }
        lens = newLens
        UserDefaults.standard.set(newLens.rawValue, forKey: "camera.lens")
        depthBackgroundReady = false
        sessionQueue.async { self.configureInput(newLens) }
    }

    func setDetectionEnabled(_ on: Bool) {
        let t = target
        let c = minConfidence
        videoQueue.async {
            self.detectionEnabled = on
            self.visionTarget = t
            self.visionMinConfidence = c
        }
        let d = usesDepth
        let thr = depthThreshold
        depthQueue.async {
            self.depthEnabled = on && d
            self.depth.threshold = thr
        }
    }

    /// Pushes changed settings (target, confidence, LiDAR threshold) to the processing queues.
    func refreshDetectionSettings() {
        setDetectionEnabled(true)
    }

    private func startSession() {
        let l = lens
        sessionQueue.async {
            if !self.configured { self.configure(l) }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isRunning = running
                self.refreshDetectionSettings()
            }
        }
    }

    private func configure(_ l: CameraLens) {
        session.beginConfiguration()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        depthOutput.isFilteringEnabled = true
        depthOutput.alwaysDiscardsLateDepthData = true
        depthOutput.setDelegate(self, callbackQueue: depthQueue)
        session.commitConfiguration()
        configured = true
        configureInput(l)
    }

    private func configureInput(_ l: CameraLens) {
        guard let device = AVCaptureDevice.default(l.deviceType, for: .video, position: .back) else {
            DispatchQueue.main.async { self.errorText = "Objektiv není k dispozici" }
            return
        }
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        input = nil
        if session.outputs.contains(depthOutput) { session.removeOutput(depthOutput) }

        if l == .lidar {
            session.sessionPreset = .inputPriority
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            }
        } catch {
            DispatchQueue.main.async { self.errorText = "Kameru nelze otevřít: \(error.localizedDescription)" }
        }

        if l == .lidar {
            if session.canAddOutput(depthOutput) { session.addOutput(depthOutput) }
            configureLidarFormat(device)
        }

        if let c = output.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
        if l == .lidar, let c = depthOutput.connection(with: .depthData), c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
        session.commitConfiguration()

        do {
            try device.lockForConfiguration()
            let supports30 = device.activeFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= 30 && 30 <= $0.maxFrameRate
            }
            if supports30 {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
        } catch {}

        let enabled = DispatchQueue.main.sync { (self.target, self.minConfidence, self.depthThreshold) }
        videoQueue.async {
            self.lastAspect = 0
            self.visionTarget = enabled.0
            self.visionMinConfidence = enabled.1
        }
        depthQueue.async {
            self.depth.reset()
            self.depth.threshold = enabled.2
            self.depthEnabled = (l == .lidar)
        }
        DispatchQueue.main.async { self.depthBackgroundReady = false }
    }

    private func configureLidarFormat(_ device: AVCaptureDevice) {
        // Pick a video format around 1280–1920 px wide that offers depth, preferring 16:9.
        let candidates = device.formats.filter { !$0.supportedDepthDataFormats.isEmpty }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions {
            CMVideoFormatDescriptionGetDimensions(f.formatDescription)
        }
        let sorted = candidates.sorted { a, b in
            let da = dims(a), db = dims(b)
            let sa = abs(Int(da.width) - 1600) + (da.width * 9 == da.height * 16 ? 0 : 400)
            let sb = abs(Int(db.width) - 1600) + (db.width * 9 == db.height * 16 ? 0 : 400)
            return sa < sb
        }
        guard let format = sorted.first else {
            DispatchQueue.main.async { self.errorText = "LiDAR: žádný formát s hloubkou" }
            return
        }
        let depthFormat = format.supportedDepthDataFormats.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat32
        } ?? format.supportedDepthDataFormats.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_DepthFloat16
        } ?? format.supportedDepthDataFormats.first
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            if let df = depthFormat { device.activeDepthDataFormat = df }
            device.unlockForConfiguration()
        } catch {
            DispatchQueue.main.async { self.errorText = "LiDAR nelze nastavit: \(error.localizedDescription)" }
        }
    }

    // MARK: - Exposure control for calibration

    /// Darkens the image (exposure bias) and locks white balance so the weak laser dot stands out.
    func prepareCalibrationExposure(bias: Float) {
        sessionQueue.async {
            guard let d = self.input?.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                let b = max(d.minExposureTargetBias, min(d.maxExposureTargetBias, bias))
                d.setExposureTargetBias(b, completionHandler: nil)
                if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
                if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    /// Freezes exposure so frame differences come only from the laser dot.
    func lockExposure() {
        sessionQueue.async {
            guard let d = self.input?.device else { return }
            do {
                try d.lockForConfiguration()
                if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    func restoreExposure() {
        sessionQueue.async {
            guard let d = self.input?.device else { return }
            do {
                try d.lockForConfiguration()
                d.setExposureTargetBias(0, completionHandler: nil)
                if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
                if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                d.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - LiDAR background

    /// Starts collecting depth frames of the empty floor (median is taken in finishDepthLearning).
    func beginDepthLearning() {
        guard usesDepth else { return }
        depthLearning = true
        depthQueue.async { self.depth.beginLearning() }
    }

    func finishDepthLearning() {
        guard usesDepth else { return }
        depthQueue.async {
            let ok = self.depth.finishLearning()
            DispatchQueue.main.async {
                self.depthLearning = false
                self.depthBackgroundReady = ok
            }
        }
    }

    // MARK: - Frame grabbing (calibration)

    func grabFrame(after delay: Double = 0, completion: @escaping (RedFrame) -> Void) {
        let notBefore = CACurrentMediaTime() + delay
        grabLock.lock()
        grabRequests.append((notBefore, completion))
        grabLock.unlock()
    }

    func grabFrame(after delay: Double = 0) async -> RedFrame {
        await withCheckedContinuation { cont in
            grabFrame(after: delay) { cont.resume(returning: $0) }
        }
    }

    private static func rednessFrame(_ pb: CVPixelBuffer, time: CFTimeInterval) -> RedFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<h {
                let row = src + y * bpr
                let o = y * w
                for x in 0..<w {
                    let p = row + x * 4
                    let v = (2 * Int(p[2]) - Int(p[1]) - Int(p[0])) / 2 // BGRA
                    dst[o + x] = UInt8(clamping: v)
                }
            }
        }
        return RedFrame(width: w, height: h, data: out, time: time)
    }
}

// MARK: - Video

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()

        let aspect = CGFloat(CVPixelBufferGetWidth(pb)) / CGFloat(max(1, CVPixelBufferGetHeight(pb)))
        if abs(aspect - lastAspect) > 0.001 {
            lastAspect = aspect
            DispatchQueue.main.async { self.imageAspect = aspect }
        }

        frameCount += 1
        if fpsWindowStart == 0 { fpsWindowStart = now }
        if now - fpsWindowStart >= 1 {
            let f = Double(frameCount) / (now - fpsWindowStart)
            let d = Double(detectCount) / (now - fpsWindowStart)
            frameCount = 0
            detectCount = 0
            fpsWindowStart = now
            DispatchQueue.main.async {
                self.fps = f
                self.detectFps = d
            }
        }

        grabLock.lock()
        let due = grabRequests.filter { $0.notBefore <= now }
        grabRequests.removeAll { $0.notBefore <= now }
        grabLock.unlock()
        if !due.isEmpty, let frame = Self.rednessFrame(pb, time: now) {
            DispatchQueue.main.async {
                for r in due { r.completion(frame) }
            }
        }

        // Vision detection (~12 Hz). With the LiDAR lens the depth detector is used instead.
        guard detectionEnabled, !depthEnabled, !visionBusy, now - lastVisionStart >= 1.0 / 12.0 else { return }
        visionBusy = true
        lastVisionStart = now
        let tgt = visionTarget
        let minConf = visionMinConfidence
        visionQueue.async {
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            var bestRect: CGRect?
            var bestConf: Float = 0
            do {
                switch tgt {
                case .cat:
                    try handler.perform([self.animalRequest])
                    for obs in self.animalRequest.results ?? [] {
                        guard let label = obs.labels.first(where: { $0.identifier.lowercased() == "cat" }) else { continue }
                        if label.confidence > bestConf {
                            bestConf = label.confidence
                            bestRect = obs.boundingBox
                        }
                    }
                case .human:
                    try handler.perform([self.humanRequest])
                    for obs in self.humanRequest.results ?? [] where obs.confidence > bestConf {
                        bestConf = obs.confidence
                        bestRect = obs.boundingBox
                    }
                }
            } catch {}

            var det: CatDetection?
            if let r = bestRect, bestConf >= minConf {
                det = CatDetection(rect: CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height),
                                   confidence: bestConf, time: now)
            }
            self.videoQueue.async {
                self.visionBusy = false
                self.detectCount += 1
            }
            DispatchQueue.main.async {
                self.lastDetectionConfidence = bestConf
                if let d = det { self.detection = d }
            }
        }
    }
}

// MARK: - Depth (LiDAR)

extension CameraManager: AVCaptureDepthDataOutputDelegate {
    func depthDataOutput(_ output: AVCaptureDepthDataOutput, didOutput depthData: AVDepthData,
                         timestamp: CMTime, connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        let converted = depthData.depthDataType == kCVPixelFormatType_DepthFloat32
            ? depthData
            : depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = converted.depthDataMap

        if depth.isLearning {
            depth.addLearningSample(map, time: now)
            return
        }
        guard depthEnabled, now - lastDepthProcess >= 1.0 / 15.0 else { return }
        lastDepthProcess = now

        let result = depth.detect(map)
        depthCount += 1
        if depthWindowStart == 0 { depthWindowStart = now }
        if now - depthWindowStart >= 1 {
            let rate = Double(depthCount) / (now - depthWindowStart)
            depthCount = 0
            depthWindowStart = now
            DispatchQueue.main.async { self.detectFps = rate }
        }
        DispatchQueue.main.async {
            if let r = result {
                self.lastDetectionConfidence = 1
                self.detection = CatDetection(rect: r, confidence: 1, time: now)
            } else {
                self.lastDetectionConfidence = 0
            }
        }
    }
}

// MARK: - Depth detector

/// Finds objects standing on the floor by comparing LiDAR depth against a learned empty-floor background.
final class DepthDetector {
    var threshold: Float = 0.05
    private(set) var isLearning = false
    private var samples: [[Float]] = []
    private var lastSampleTime: CFTimeInterval = 0
    private var background: [Float]?
    private var width = 0
    private var height = 0

    func reset() {
        isLearning = false
        samples = []
        background = nil
    }

    func beginLearning() {
        samples = []
        isLearning = true
        lastSampleTime = 0
    }

    func addLearningSample(_ map: CVPixelBuffer, time: CFTimeInterval) {
        guard time - lastSampleTime >= 0.4, samples.count < 40, let r = Self.read(map) else { return }
        let (w, h, d) = r
        lastSampleTime = time
        if w != width || h != height { samples = []; width = w; height = h }
        samples.append(d)
    }

    /// Per-pixel median of the collected samples.
    func finishLearning() -> Bool {
        isLearning = false
        guard samples.count >= 3 else { return false }
        let n = width * height
        var bg = [Float](repeating: 0, count: n)
        var column = [Float]()
        column.reserveCapacity(samples.count)
        for i in 0..<n {
            column.removeAll(keepingCapacity: true)
            for s in samples where s[i].isFinite && s[i] > 0 { column.append(s[i]) }
            if column.count >= 2 {
                column.sort()
                bg[i] = column[column.count / 2]
            }
        }
        background = bg
        samples = []
        return true
    }

    /// Returns the bounding box (normalised, portrait, top-left origin) of the largest object above the floor.
    func detect(_ map: CVPixelBuffer) -> CGRect? {
        guard let bg = background, let r = Self.read(map) else { return nil }
        let (w, h, d) = r
        guard w == width, h == height else { return nil }
        let n = w * h
        var mask = [Bool](repeating: false, count: n)
        for i in 0..<n {
            let b = bg[i], v = d[i]
            if b > 0, v.isFinite, v > 0 {
                let diff = b - v
                mask[i] = diff > threshold && diff < 1.5
            }
        }
        // Largest 4-connected component.
        var visited = [Bool](repeating: false, count: n)
        var bestCount = 0
        var best = (minX: 0, minY: 0, maxX: 0, maxY: 0)
        var stack: [Int] = []
        for start in 0..<n where mask[start] && !visited[start] {
            var count = 0
            var bx = (minX: Int.max, minY: Int.max, maxX: 0, maxY: 0)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            visited[start] = true
            while let i = stack.popLast() {
                count += 1
                let x = i % w, y = i / w
                bx.minX = min(bx.minX, x); bx.maxX = max(bx.maxX, x)
                bx.minY = min(bx.minY, y); bx.maxY = max(bx.maxY, y)
                if x > 0, mask[i - 1], !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                if x < w - 1, mask[i + 1], !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                if y > 0, mask[i - w], !visited[i - w] { visited[i - w] = true; stack.append(i - w) }
                if y < h - 1, mask[i + w], !visited[i + w] { visited[i + w] = true; stack.append(i + w) }
            }
            if count > bestCount {
                bestCount = count
                best = bx
            }
        }
        guard bestCount >= max(30, n / 400) else { return nil }

        let x0 = CGFloat(best.minX) / CGFloat(w), x1 = CGFloat(best.maxX + 1) / CGFloat(w)
        let y0 = CGFloat(best.minY) / CGFloat(h), y1 = CGFloat(best.maxY + 1) / CGFloat(h)
        if w > h {
            // Depth map still in sensor (landscape) orientation → rotate to portrait: xp = 1 − ys, yp = xs.
            return CGRect(x: 1 - y1, y: x0, width: y1 - y0, height: x1 - x0)
        }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    private static func read(_ map: CVPixelBuffer) -> (Int, Int, [Float])? {
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map)
        let h = CVPixelBufferGetHeight(map)
        let bpr = CVPixelBufferGetBytesPerRow(map)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * bpr).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { out[y * w + x] = row[x] }
        }
        return (w, h, out)
    }
}

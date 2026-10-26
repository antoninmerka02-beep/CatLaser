import Foundation
import AVFoundation
import Vision
import QuartzCore
import CoreGraphics

/// Downsampled red channel of one camera frame (used for laser-dot detection).
struct RedFrame {
    let width: Int
    let height: Int
    let data: [UInt8]
    let time: CFTimeInterval
}

/// Cat detection in normalised image coordinates (origin top-left, 0…1).
struct CatDetection {
    let rect: CGRect
    let confidence: Float
    let time: CFTimeInterval
}

enum CameraLens: String, CaseIterable, Identifiable, Codable {
    case ultraWide
    case standard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraWide: return "Širokoúhlý 0,5×"
        case .standard: return "Standardní 1×"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .standard: return .builtInWideAngleCamera
        }
    }

    var isAvailable: Bool {
        AVCaptureDevice.default(deviceType, for: .video, position: .back) != nil
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

    /// Minimum Vision confidence for a cat.
    @Published var minConfidence: Float = UserDefaults.standard.object(forKey: "camera.minConfidence") as? Float ?? 0.3 {
        didSet { UserDefaults.standard.set(minConfidence, forKey: "camera.minConfidence") }
    }

    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.video")
    private let visionQueue = DispatchQueue(label: "camera.vision")
    private let output = AVCaptureVideoDataOutput()
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

    private lazy var animalRequest: VNRecognizeAnimalsRequest = VNRecognizeAnimalsRequest()

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
        guard newLens.isAvailable else { return }
        lens = newLens
        UserDefaults.standard.set(newLens.rawValue, forKey: "camera.lens")
        sessionQueue.async { self.configureInput() }
    }

    func setDetectionEnabled(_ on: Bool) {
        videoQueue.async { self.detectionEnabled = on }
    }

    private func startSession() {
        sessionQueue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
            let running = self.session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        configured = true
        configureInput()
    }

    private func configureInput() {
        let lensNow = DispatchQueue.main.sync { self.lens }
        guard let device = AVCaptureDevice.default(lensNow.deviceType, for: .video, position: .back) else {
            DispatchQueue.main.async { self.errorText = "Objektiv není k dispozici" }
            return
        }
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            }
        } catch {
            DispatchQueue.main.async { self.errorText = "Kameru nelze otevřít: \(error.localizedDescription)" }
        }
        if let c = output.connection(with: .video), c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
        session.commitConfiguration()

        // Steady ~30 fps, continuous focus/exposure.
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
    }

    // MARK: - Frame grabbing (calibration)

    /// Delivers the red channel of the first frame captured after `delay` seconds (on the main queue).
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

    private static func redChannel(_ pb: CVPixelBuffer, step: Int, time: CFTimeInterval) -> RedFrame? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let ow = w / step, oh = h / step
        var out = [UInt8](repeating: 0, count: ow * oh)
        let src = base.assumingMemoryBound(to: UInt8.self)
        out.withUnsafeMutableBufferPointer { dst in
            for y in 0..<oh {
                let row = src + (y * step) * bpr
                let o = y * ow
                for x in 0..<ow {
                    dst[o + x] = row[(x * step) * 4 + 2] // BGRA → R
                }
            }
        }
        return RedFrame(width: ow, height: oh, data: out, time: time)
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()

        // FPS statistics
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

        // Pending frame grabs
        grabLock.lock()
        let due = grabRequests.filter { $0.notBefore <= now }
        grabRequests.removeAll { $0.notBefore <= now }
        grabLock.unlock()
        if !due.isEmpty, let frame = Self.redChannel(pb, step: 2, time: now) {
            DispatchQueue.main.async {
                for r in due { r.completion(frame) }
            }
        }

        // Cat detection (~12 Hz)
        guard detectionEnabled, !visionBusy, now - lastVisionStart >= 1.0 / 12.0 else { return }
        visionBusy = true
        lastVisionStart = now
        visionQueue.async {
            let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
            var best: VNRecognizedObjectObservation?
            var bestConf: Float = 0
            do {
                try handler.perform([self.animalRequest])
                for obs in self.animalRequest.results ?? [] {
                    guard let label = obs.labels.first(where: { $0.identifier.lowercased() == "cat" }) else { continue }
                    if label.confidence > bestConf {
                        bestConf = label.confidence
                        best = obs
                    }
                }
            } catch {}

            var det: CatDetection?
            if let b = best, bestConf >= self.minConfidence {
                let r = b.boundingBox // Vision: origin bottom-left
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

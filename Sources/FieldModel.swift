import Foundation
import CoreGraphics
import QuartzCore
import Combine

/// Calibration result for one camera lens.
struct CalibrationData: Codable {
    /// Camera (normalised 0…1, top-left) → laser (0…400).
    var camToLaser: Homography
    /// Area the laser can reach AND the camera can see, in laser coordinates.
    var reach: [CGPoint]
    var points: Int
    var rmsError: Double
    var date: Date
}

/// Cat state in laser coordinates.
struct CatState {
    var position: CGPoint      // ground point (bottom centre of the box) in laser units
    var velocity: CGPoint      // laser units / s
    var size: CGFloat          // approx. body width in laser units
    var polygon: [CGPoint]     // bounding box projected to the floor (laser units)
    var rect: CGRect           // normalised camera rect (for drawing)
    var confidence: Float
    var time: CFTimeInterval
}

final class FieldModel: ObservableObject {
    @Published private(set) var calibration: CalibrationData?
    @Published var fence: [CGPoint] = [] { didSet { saveFence() } }
    @Published var editingFence = false
    @Published private(set) var cat: CatState?

    // Calibration progress
    @Published var calibrating = false
    @Published var calibrationProgress: Double = 0
    @Published var calibrationStatus = ""
    @Published var lastDotCam: CGPoint?

    private(set) var laserToCam: Homography?
    private var lens: CameraLens = .standard
    private var cancellables = Set<AnyCancellable>()

    static let margin: CGFloat = 12

    init(camera: CameraManager) {
        lens = camera.lens
        loadFence()
        loadCalibration()
        camera.$lens
            .removeDuplicates()
            .sink { [weak self] l in
                self?.lens = l
                self?.loadCalibration()
            }
            .store(in: &cancellables)
        camera.$detection
            .compactMap { $0 }
            .sink { [weak self] d in self?.updateCat(d) }
            .store(in: &cancellables)
    }

    var isCalibrated: Bool { calibration != nil }

    // MARK: - Coordinate conversion

    func camToLaser(_ p: CGPoint) -> CGPoint? {
        guard let h = calibration?.camToLaser, h.w(p) > 0 else { return nil }
        return h.apply(p)
    }

    func laserToCamPoint(_ p: CGPoint) -> CGPoint? {
        laserToCam?.apply(p)
    }

    // MARK: - Play field

    /// Polygons the dot must stay inside (reachable area, plus the fence if set).
    var playPolygons: [[CGPoint]] {
        var polys: [[CGPoint]] = []
        if let r = calibration?.reach, r.count >= 3 { polys.append(r) }
        if fence.count >= 3 { polys.append(fence) }
        return polys
    }

    var playCenter: CGPoint {
        if fence.count >= 3 { return Poly.centroid(fence) }
        if let r = calibration?.reach, r.count >= 3 { return Poly.centroid(r) }
        return CGPoint(x: 200, y: 200)
    }

    func isInside(_ p: CGPoint) -> Bool {
        playPolygons.allSatisfy { Poly.contains($0, p) }
    }

    func constrain(_ p: CGPoint) -> CGPoint {
        var q = p.clamped(0, 400)
        let polys = playPolygons
        guard !polys.isEmpty else { return q }
        for _ in 0..<4 {
            var moved = false
            for poly in polys where !Poly.contains(poly, q) {
                q = Poly.pullInside(poly, q, margin: Self.margin)
                moved = true
            }
            if !moved { break }
        }
        // Last resort when fence and reach barely overlap: stay inside the fence.
        if !isInside(q), let last = polys.last {
            q = Poly.pullInside(last, q, margin: Self.margin)
        }
        return q.clamped(0, 400)
    }

    func distanceToEdge(_ p: CGPoint) -> CGFloat {
        let polys = playPolygons
        guard !polys.isEmpty else {
            return min(p.x, p.y, 400 - p.x, 400 - p.y)
        }
        return polys.map { Poly.contains($0, p) ? Poly.distanceToBoundary($0, p) : 0 }.min() ?? 0
    }

    func randomPoint(farFrom c: CGPoint) -> CGPoint {
        var best = playCenter
        var bestD: CGFloat = -1
        for _ in 0..<24 {
            let p = constrain(CGPoint(x: CGFloat.random(in: 20...380), y: CGFloat.random(in: 20...380)))
            let d = p.distance(to: c)
            if d > bestD { bestD = d; best = p }
        }
        return best
    }

    // MARK: - Fence editing (input in camera-normalised coordinates)

    func addFencePoint(cam: CGPoint) {
        guard let p = camToLaser(cam) else { return }
        fence.append(p.clamped(-50, 450))
    }

    func moveFencePoint(_ i: Int, cam: CGPoint) {
        guard fence.indices.contains(i), let p = camToLaser(cam) else { return }
        fence[i] = p.clamped(-50, 450)
    }

    func nearestFenceIndex(cam: CGPoint, maxDistance: CGFloat) -> Int? {
        var best: Int?
        var bestD = maxDistance
        for (i, p) in fence.enumerated() {
            guard let c = laserToCamPoint(p) else { continue }
            let d = c.distance(to: cam)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func removeLastFencePoint() {
        if !fence.isEmpty { fence.removeLast() }
    }

    func clearFence() { fence = [] }

    // MARK: - Cat tracking

    private func updateCat(_ d: CatDetection) {
        guard calibration != nil else { return }
        let r = d.rect
        guard let ground = camToLaser(CGPoint(x: r.midX, y: r.maxY)) else { return }
        let bl = camToLaser(CGPoint(x: r.minX, y: r.maxY))
        let br = camToLaser(CGPoint(x: r.maxX, y: r.maxY))
        var size: CGFloat = 40
        if let a = bl, let b = br { size = max(15, a.distance(to: b)) }

        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                       CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        var poly = corners.compactMap { camToLaser($0) }
        if poly.count < 3 {
            poly = [ground + CGPoint(x: -size, y: -size), ground + CGPoint(x: size, y: -size),
                    ground + CGPoint(x: size, y: size), ground + CGPoint(x: -size, y: size)]
        }

        var vel = CGPoint.zero
        if let prev = cat {
            let dt = CGFloat(d.time - prev.time)
            if dt > 0.02 && dt < 0.6 {
                var inst = (ground - prev.position) * (1 / dt)
                if inst.length > 1500 { inst = inst.normalized * 1500 }
                vel = prev.velocity * 0.55 + inst * 0.45
            }
        }
        cat = CatState(position: ground, velocity: vel, size: size, polygon: poly,
                       rect: r, confidence: d.confidence, time: d.time)
    }

    // MARK: - Calibration

    @MainActor
    func calibrate(laser: LaserController, camera: CameraManager) async {
        guard laser.isReady else {
            calibrationStatus = "Nejdřív se připoj k laseru (záložka Test)."
            return
        }
        guard camera.isRunning else {
            calibrationStatus = "Kamera neběží."
            return
        }
        calibrating = true
        calibrationProgress = 0
        lastDotCam = nil
        camera.setDetectionEnabled(false)
        defer {
            calibrating = false
            camera.setDetectionEnabled(true)
        }

        laser.pattern = .none
        if laser.preset != 0 { laser.setPreset(0) }
        laser.addLog("Kalibrace: start")

        calibrationStatus = "Snímám pozadí (laser vypnutý)…"
        laser.setLaser(false)
        var background = await averaged(camera, delay: 0.7)
        laser.setLaser(true)

        let coords: [CGFloat] = [40, 147, 253, 360]
        var targets: [CGPoint] = []
        for (row, y) in coords.enumerated() {
            let xs: [CGFloat] = row % 2 == 0 ? coords : Array(coords.reversed())
            for x in xs { targets.append(CGPoint(x: x, y: y)) }
        }

        var camPts: [CGPoint] = []
        var laserPts: [CGPoint] = []
        for (i, t) in targets.enumerated() {
            if i == targets.count / 2 {
                calibrationStatus = "Obnovuji pozadí…"
                laser.setLaser(false)
                background = await averaged(camera, delay: 0.6)
                laser.setLaser(true)
            }
            calibrationStatus = "Bod \(i + 1) z \(targets.count)"
            laser.gameMove(x: Int(t.x), y: Int(t.y))
            let on1 = await camera.grabFrame(after: 0.75)
            let on2 = await camera.grabFrame(after: 0.05)
            if let dot = DotDetector.detect(on: [on1, on2], off: background) {
                camPts.append(dot.point)
                laserPts.append(t)
                lastDotCam = dot.point
                laser.addLog(String(format: "Kalibrace bod %d: laser (%.0f, %.0f) → kamera (%.3f, %.3f), síla %d",
                                    i + 1, t.x, t.y, dot.point.x, dot.point.y, dot.strength))
            } else {
                laser.addLog(String(format: "Kalibrace bod %d (%.0f, %.0f): tečka nenalezena", i + 1, t.x, t.y))
            }
            calibrationProgress = Double(i + 1) / Double(targets.count)
        }
        laser.gameMove(x: 200, y: 200)

        guard camPts.count >= 6 else {
            calibrationStatus = "Kalibrace selhala: tečka nalezena jen v \(camPts.count) bodech z \(targets.count). Ztlum světlo nebo natoč kameru na plochu, kam laser svítí."
            laser.addLog(calibrationStatus)
            return
        }

        guard let result = Self.robustFit(cam: camPts, laser: laserPts) else {
            calibrationStatus = "Kalibrace selhala: body nedávají smysl (kamera se hýbala?)."
            laser.addLog(calibrationStatus)
            return
        }

        let data = CalibrationData(camToLaser: result.h, reach: Poly.convexHull(result.inliers),
                                   points: result.inliers.count, rmsError: result.rms, date: Date())
        setCalibration(data)
        calibrationStatus = String(format: "Hotovo: %d bodů, přesnost ±%.1f (z 400).", data.points, data.rmsError)
        laser.addLog("Kalibrace: " + calibrationStatus)
    }

    private func averaged(_ camera: CameraManager, delay: Double) async -> RedFrame {
        let a = await camera.grabFrame(after: delay)
        let b = await camera.grabFrame(after: 0.05)
        var out = a.data
        for i in 0..<min(out.count, b.data.count) {
            out[i] = UInt8((Int(a.data[i]) + Int(b.data[i])) / 2)
        }
        return RedFrame(width: a.width, height: a.height, data: out, time: b.time)
    }

    /// Fits camera→laser with simple outlier rejection. Laser coords are scaled to 0…1 for stability.
    static func robustFit(cam: [CGPoint], laser: [CGPoint]) -> (h: Homography, inliers: [CGPoint], rms: Double)? {
        var c = cam
        var l = laser
        while c.count >= 5 {
            let ln = l.map { CGPoint(x: $0.x / 400, y: $0.y / 400) }
            guard let hn = Homography.fit(src: c, dst: ln) else { return nil }
            var m = hn.m
            for k in 0..<6 { m[k] *= 400 }
            let h = Homography(m: m)
            let errs: [Double] = zip(c, l).map { pair in
                guard let p = h.apply(pair.0) else { return 1e9 }
                return Double(p.distance(to: pair.1))
            }
            let rms = (errs.map { $0 * $0 }.reduce(0, +) / Double(errs.count)).squareRoot()
            if let maxE = errs.max(), maxE > 15, c.count > 6, let idx = errs.firstIndex(of: maxE) {
                c.remove(at: idx)
                l.remove(at: idx)
                continue
            }
            guard rms < 25 else { return nil }
            return (h, l, rms)
        }
        return nil
    }

    // MARK: - Persistence

    private func setCalibration(_ data: CalibrationData) {
        calibration = data
        laserToCam = data.camToLaser.inverted()
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "calibration.\(lens.rawValue)")
        }
    }

    func clearCalibration() {
        calibration = nil
        laserToCam = nil
        UserDefaults.standard.removeObject(forKey: "calibration.\(lens.rawValue)")
    }

    private func loadCalibration() {
        cat = nil
        if let d = UserDefaults.standard.data(forKey: "calibration.\(lens.rawValue)"),
           let c = try? JSONDecoder().decode(CalibrationData.self, from: d) {
            calibration = c
            laserToCam = c.camToLaser.inverted()
        } else {
            calibration = nil
            laserToCam = nil
        }
    }

    private func saveFence() {
        let arr = fence.map { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(arr, forKey: "fence")
    }

    private func loadFence() {
        if let arr = UserDefaults.standard.array(forKey: "fence") as? [[Double]] {
            fence = arr.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
    }
}

// MARK: - Laser dot detection

enum DotDetector {
    struct Result {
        let point: CGPoint   // normalised camera coordinates
        let strength: Int
    }

    /// Finds the laser dot as the strongest red-channel increase between "on" frames and the "off" background.
    static func detect(on frames: [RedFrame], off: RedFrame, minStrength: Int = 35) -> Result? {
        guard let first = frames.first else { return nil }
        let w = first.width, h = first.height
        guard off.width == w, off.height == h else { return nil }
        let n = w * h

        // Use the per-pixel minimum of the "on" frames to suppress transient motion.
        var diff = [Int16](repeating: 0, count: n)
        for i in 0..<n {
            var v = Int(first.data[i])
            for f in frames.dropFirst() where f.data.count == n { v = min(v, Int(f.data[i])) }
            diff[i] = Int16(v - Int(off.data[i]))
        }

        var maxV: Int16 = 0
        var maxI = 0
        for i in 0..<n where diff[i] > maxV {
            maxV = diff[i]
            maxI = i
        }
        guard Int(maxV) >= minStrength else { return nil }

        let mx = maxI % w, my = maxI / w
        let r = 14
        let thr = Int16(Double(maxV) * 0.5)
        var sx = 0.0, sy = 0.0, sw = 0.0
        var count = 0
        for y in max(0, my - r)...min(h - 1, my + r) {
            for x in max(0, mx - r)...min(w - 1, mx + r) {
                let v = diff[y * w + x]
                if v >= thr {
                    let wt = Double(v)
                    sx += Double(x) * wt
                    sy += Double(y) * wt
                    sw += wt
                    count += 1
                }
            }
        }
        // A real dot is small and compact – reject large blobs (lighting change, moving object).
        guard sw > 0, count < 250 else { return nil }
        let cx = (sx / sw + 0.5) / Double(w)
        let cy = (sy / sw + 0.5) / Double(h)
        return Result(point: CGPoint(x: cx, y: cy), strength: Int(maxV))
    }
}

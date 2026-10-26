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

/// Tracked target (cat or person) in laser coordinates.
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
    /// Hard limits of the laser itself (laser coordinates). Nothing is ever sent outside.
    @Published var limits: [CGPoint] = [] { didSet { saveLimits() } }
    /// Play area drawn on the camera image (normalised camera coordinates, per lens).
    @Published var fenceCam: [CGPoint] = [] { didSet { saveFence() } }
    @Published var editingFence = false
    @Published private(set) var cat: CatState?

    // Calibration progress
    @Published var calibrating = false
    @Published var calibrationProgress: Double = 0
    @Published var calibrationStatus = ""
    @Published var lastDotCam: CGPoint?
    @Published var calibrationDots: [CGPoint] = []
    var cancelRequested = false

    private(set) var laserToCam: Homography?
    private(set) var fenceLaser: [CGPoint] = []
    private var lens: CameraLens = .standard
    private var loadingFence = false
    private var cancellables = Set<AnyCancellable>()

    static let margin: CGFloat = 10

    init(camera: CameraManager) {
        lens = camera.lens
        loadLimits()
        loadCalibration()
        loadFence()
        camera.$lens
            .removeDuplicates()
            .sink { [weak self] l in
                guard let self = self, l != self.lens else { return }
                self.lens = l
                self.loadCalibration()
                self.loadFence()
            }
            .store(in: &cancellables)
        camera.$detection
            .compactMap { $0 }
            .sink { [weak self] d in self?.updateCat(d) }
            .store(in: &cancellables)
    }

    var isCalibrated: Bool { calibration != nil }
    var hasLimits: Bool { limits.count >= 3 }

    // MARK: - Coordinate conversion

    func camToLaser(_ p: CGPoint) -> CGPoint? {
        guard let h = calibration?.camToLaser, h.w(p) > 0 else { return nil }
        return h.apply(p)
    }

    func laserToCamPoint(_ p: CGPoint) -> CGPoint? {
        laserToCam?.apply(p)
    }

    // MARK: - Play field

    /// Polygons the dot must stay inside: laser limits, calibrated reach and the drawn play area.
    var playPolygons: [[CGPoint]] {
        var polys: [[CGPoint]] = []
        if limits.count >= 3 { polys.append(limits) }
        if let r = calibration?.reach, r.count >= 3 { polys.append(r) }
        if fenceLaser.count >= 3 { polys.append(fenceLaser) }
        return polys
    }

    var playCenter: CGPoint {
        if fenceLaser.count >= 3 { return Poly.centroid(fenceLaser) }
        if let r = calibration?.reach, r.count >= 3 { return Poly.centroid(r) }
        if limits.count >= 3 { return Poly.centroid(limits) }
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
        // Laser limits always win.
        if limits.count >= 3 && !Poly.contains(limits, q) {
            q = Poly.pullInside(limits, q, margin: Self.margin)
        }
        return q.clamped(0, 400)
    }

    /// Constrains only to the hard laser limits (used during calibration).
    func constrainToLimits(_ p: CGPoint) -> CGPoint {
        guard limits.count >= 3, !Poly.contains(limits, p) else { return p.clamped(0, 400) }
        return Poly.pullInside(limits, p, margin: 2).clamped(0, 400)
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

    // MARK: - Laser limits (laser coordinates)

    func addLimitPoint(_ p: CGPoint) { limits.append(p.clamped(0, 400)) }
    func removeLastLimitPoint() { if !limits.isEmpty { limits.removeLast() } }
    func clearLimits() { limits = [] }

    // MARK: - Play area editing (camera coordinates)

    func addFencePoint(cam: CGPoint) {
        fenceCam.append(cam.clamped(0, 1))
    }

    func moveFencePoint(_ i: Int, cam: CGPoint) {
        guard fenceCam.indices.contains(i) else { return }
        fenceCam[i] = cam.clamped(0, 1)
    }

    func nearestFenceIndex(cam: CGPoint, maxDistance: CGFloat) -> Int? {
        var best: Int?
        var bestD = maxDistance
        for (i, p) in fenceCam.enumerated() {
            let d = p.distance(to: cam)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    func removeLastFencePoint() { if !fenceCam.isEmpty { fenceCam.removeLast() } }
    func clearFence() { fenceCam = [] }

    private func updateFenceLaser() {
        if fenceCam.count >= 3, calibration != nil {
            let pts = fenceCam.compactMap { camToLaser($0) }
            fenceLaser = pts.count == fenceCam.count ? pts : []
        } else {
            fenceLaser = []
        }
    }

    // MARK: - Target tracking

    private func updateCat(_ d: CatDetection) {
        guard calibration != nil else { return }
        let r = d.rect
        guard let ground = camToLaser(CGPoint(x: r.midX, y: r.maxY)) else { return }
        let bl = camToLaser(CGPoint(x: r.minX, y: r.maxY))
        let br = camToLaser(CGPoint(x: r.maxX, y: r.maxY))
        var size: CGFloat = 40
        if let a = bl, let b = br { size = max(15, min(200, a.distance(to: b))) }

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

    /// Laser points visited during calibration: a grid inside the laser limits.
    func calibrationTargets() -> [CGPoint] {
        let poly = limits.count >= 3 ? limits : [CGPoint(x: 20, y: 20), CGPoint(x: 380, y: 20),
                                                  CGPoint(x: 380, y: 380), CGPoint(x: 20, y: 380)]
        let xs = poly.map { $0.x }, ys = poly.map { $0.y }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        for n in [4, 5, 6] {
            var pts: [CGPoint] = []
            for row in 0..<n {
                let fy = (CGFloat(row) + 0.5) / CGFloat(n)
                let y = minY + (maxY - minY) * fy
                var rowPts: [CGPoint] = []
                for col in 0..<n {
                    let fx = (CGFloat(col) + 0.5) / CGFloat(n)
                    let p = CGPoint(x: minX + (maxX - minX) * fx, y: y)
                    if poly.count < 3 || Poly.contains(poly, p) { rowPts.append(p) }
                }
                pts += row % 2 == 0 ? rowPts : Array(rowPts.reversed())
            }
            if pts.count >= 12 || n == 6 { return pts }
        }
        return []
    }

    /// Automatic calibration. The laser is NOT switched off (it plays a ~5 s intro after every power-on);
    /// the dot is found as the difference between frames taken with the dot at neighbouring grid points.
    @MainActor
    func calibrate(laser: LaserController, camera: CameraManager,
                   settle: Double, warmup: Double, exposureBias: Float) async -> Bool {
        guard laser.isReady else {
            calibrationStatus = "Laser není připojený."
            return false
        }
        guard camera.isRunning else {
            calibrationStatus = "Kamera neběží."
            return false
        }
        calibrating = true
        cancelRequested = false
        calibrationProgress = 0
        lastDotCam = nil
        calibrationDots = []
        camera.setDetectionEnabled(false)
        camera.beginDepthLearning()
        defer {
            calibrating = false
            camera.restoreExposure()
            camera.setDetectionEnabled(true)
        }

        laser.pattern = .none
        if laser.preset != 0 { laser.setPreset(0) }
        laser.addLog("Kalibrace: start")

        let targets = calibrationTargets()
        guard targets.count >= 6 else {
            calibrationStatus = "Limity laseru jsou moc malé."
            camera.finishDepthLearning()
            return false
        }

        // 1) Laser on + wait for its intro animation.
        if !laser.laserOn {
            calibrationStatus = "Zapínám laser – čekám na úvodní kolečko…"
            laser.setLaser(true)
            await pause(warmup)
        }
        if cancelRequested { return cancelled(camera) }

        // 2) Darker, locked exposure so the dot stands out.
        calibrationStatus = "Nastavuji expozici…"
        camera.prepareCalibrationExposure(bias: exposureBias)
        laser.gameMove(x: Int(targets[0].x), y: Int(targets[0].y))
        await pause(1.5)
        camera.lockExposure()
        await pause(0.4)

        // 3) Visit all points and grab frames.
        var frames: [RedFrame] = []
        for (i, t) in targets.enumerated() {
            if cancelRequested { return cancelled(camera) }
            calibrationStatus = "Bod \(i + 1) z \(targets.count)"
            laser.gameMove(x: Int(t.x), y: Int(t.y))
            frames.append(await averagedFrame(camera, delay: settle))
            calibrationProgress = Double(i + 1) / Double(targets.count) * 0.95
        }
        laser.gameMove(x: Int(playCenter.x), y: Int(playCenter.y))
        camera.finishDepthLearning()

        // 4) Find the dot: compare each frame with both neighbours, accept only consistent results.
        calibrationStatus = "Hledám tečku ve snímcích…"
        let roi = searchRegion()
        var camPts: [CGPoint] = []
        var laserPts: [CGPoint] = []
        for i in 0..<frames.count {
            let refs = [i - 1, i + 1].filter { $0 >= 0 && $0 < frames.count }
            let found = refs.compactMap { DotDetector.detect(on: frames[i], ref: frames[$0], roi: roi) }
            var accepted: CGPoint?
            if found.count == 2 {
                if found[0].point.distance(to: found[1].point) < 0.03 {
                    accepted = (found[0].point + found[1].point) * 0.5
                }
            } else if found.count == 1 && refs.count == 1 && found[0].strength >= DotDetector.minStrength * 2 {
                accepted = found[0].point
            }
            let t = targets[i]
            if let a = accepted {
                camPts.append(a)
                laserPts.append(t)
                calibrationDots.append(a)
                lastDotCam = a
                laser.addLog(String(format: "Bod %d: laser (%.0f, %.0f) → kamera (%.3f, %.3f), síla %d",
                                    i + 1, t.x, t.y, a.x, a.y, found.map { $0.strength }.max() ?? 0))
            } else {
                laser.addLog(String(format: "Bod %d (%.0f, %.0f): tečka nenalezena (%d/%d shod)",
                                    i + 1, t.x, t.y, found.count, refs.count))
            }
        }
        calibrationProgress = 1

        guard camPts.count >= 6 else {
            calibrationStatus = "Kalibrace selhala: tečka nalezena jen v \(camPts.count) z \(targets.count) bodů. Zkus ztlumit světlo, snížit expozici nebo prodloužit čekání na bod."
            laser.addLog(calibrationStatus)
            return false
        }
        guard let result = Self.robustFit(cam: camPts, laser: laserPts) else {
            calibrationStatus = "Kalibrace selhala: body nedávají smysl (pohnul se telefon?)."
            laser.addLog(calibrationStatus)
            return false
        }

        let data = CalibrationData(camToLaser: result.h, reach: Poly.convexHull(result.inliers),
                                   points: result.inliers.count, rmsError: result.rms, date: Date())
        setCalibration(data)
        calibrationStatus = String(format: "Kalibrace OK: %d bodů, přesnost ±%.1f (z 400).", data.points, data.rmsError)
        laser.addLog(calibrationStatus)
        return true
    }

    private func cancelled(_ camera: CameraManager) -> Bool {
        calibrationStatus = "Kalibrace zrušena."
        camera.finishDepthLearning()
        return false
    }

    private func pause(_ s: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1_000_000_000))
    }

    /// Average of 3 consecutive frames taken `delay` seconds from now.
    private func averagedFrame(_ camera: CameraManager, delay: Double) async -> RedFrame {
        let a = await camera.grabFrame(after: delay)
        let b = await camera.grabFrame(after: 0)
        let c = await camera.grabFrame(after: 0)
        let n = min(a.data.count, b.data.count, c.data.count)
        var out = [UInt8](repeating: 0, count: a.data.count)
        for i in 0..<n {
            out[i] = UInt8((Int(a.data[i]) + Int(b.data[i]) + Int(c.data[i])) / 3)
        }
        return RedFrame(width: a.width, height: a.height, data: out, time: c.time)
    }

    /// Where to look for the dot: the drawn play area (+ margin), else the whole frame.
    private func searchRegion() -> CGRect {
        guard fenceCam.count >= 3 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let xs = fenceCam.map { $0.x }, ys = fenceCam.map { $0.y }
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return r.insetBy(dx: -0.15, dy: -0.15).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
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
        updateFenceLaser()
        if let encoded = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(encoded, forKey: "calibration.\(lens.rawValue)")
        }
    }

    func clearCalibration() {
        calibration = nil
        laserToCam = nil
        updateFenceLaser()
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
        updateFenceLaser()
    }

    private func saveFence() {
        updateFenceLaser()
        guard !loadingFence else { return }
        let arr = fenceCam.map { [Double($0.x), Double($0.y)] }
        UserDefaults.standard.set(arr, forKey: "fence.cam.\(lens.rawValue)")
    }

    private func loadFence() {
        loadingFence = true
        if let arr = UserDefaults.standard.array(forKey: "fence.cam.\(lens.rawValue)") as? [[Double]] {
            fenceCam = arr.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        } else {
            fenceCam = []
        }
        loadingFence = false
        updateFenceLaser()
    }

    private func saveLimits() {
        UserDefaults.standard.set(limits.map { [Double($0.x), Double($0.y)] }, forKey: "laser.limits")
    }

    private func loadLimits() {
        if let arr = UserDefaults.standard.array(forKey: "laser.limits") as? [[Double]] {
            limits = arr.compactMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
        }
    }
}

// MARK: - Laser dot detection

enum DotDetector {
    struct Result {
        let point: CGPoint   // normalised camera coordinates
        let strength: Int
    }

    static let minStrength = 10

    /// Finds the laser dot as the strongest compact increase of "redness" between `on` (dot here)
    /// and `ref` (dot somewhere else). Peak is evaluated on 3×3 means to ignore single noisy pixels.
    static func detect(on: RedFrame, ref: RedFrame, roi: CGRect) -> Result? {
        let w = on.width, h = on.height
        guard ref.width == w, ref.height == h, w > 4, h > 4 else { return nil }
        let x0 = max(1, Int(roi.minX * CGFloat(w))), x1 = min(w - 2, Int(roi.maxX * CGFloat(w)))
        let y0 = max(1, Int(roi.minY * CGFloat(h))), y1 = min(h - 2, Int(roi.maxY * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return nil }

        var bestMean = 0
        var bestX = 0, bestY = 0
        let pre = minStrength / 2
        on.data.withUnsafeBufferPointer { a in
            ref.data.withUnsafeBufferPointer { b in
                for y in y0...y1 {
                    let row = y * w
                    for x in x0...x1 {
                        let i = row + x
                        if Int(a[i]) - Int(b[i]) <= pre { continue }
                        var s = 0
                        for dy in -1...1 {
                            let r = i + dy * w
                            s += Int(a[r - 1]) - Int(b[r - 1]) + Int(a[r]) - Int(b[r]) + Int(a[r + 1]) - Int(b[r + 1])
                        }
                        let mean = s / 9
                        if mean > bestMean {
                            bestMean = mean
                            bestX = x
                            bestY = y
                        }
                    }
                }
            }
        }
        guard bestMean >= minStrength else { return nil }

        // Weighted centroid of the blob around the peak + compactness check.
        let rad = 24
        let thr = max(pre, bestMean / 2)
        var sx = 0.0, sy = 0.0, sw = 0.0
        var count = 0
        for y in max(0, bestY - rad)...min(h - 1, bestY + rad) {
            for x in max(0, bestX - rad)...min(w - 1, bestX + rad) {
                let v = Int(on.data[y * w + x]) - Int(ref.data[y * w + x])
                if v >= thr {
                    sx += Double(x) * Double(v)
                    sy += Double(y) * Double(v)
                    sw += Double(v)
                    count += 1
                }
            }
        }
        guard sw > 0, count >= 2, count < 1200 else { return nil }
        return Result(point: CGPoint(x: (sx / sw + 0.5) / Double(w), y: (sy / sw + 0.5) / Double(h)),
                      strength: bestMean)
    }
}

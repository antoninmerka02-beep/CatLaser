import Foundation
import CoreGraphics
import QuartzCore

private func storedDouble(_ key: String, _ def: Double) -> Double {
    UserDefaults.standard.object(forKey: key) as? Double ?? def
}

private func storedBool(_ key: String, _ def: Bool) -> Bool {
    UserDefaults.standard.object(forKey: key) as? Bool ?? def
}

/// Moves the laser dot like prey: lures, flees, freezes, dashes away, lets itself be caught.
/// The laser is never switched off during play (it runs a ~5 s intro animation after every power-on),
/// except when the target leaves the view and the safety option asks for it.
final class PreyEngine: ObservableObject {
    enum Mode: String {
        case off = "Vypnuto"
        case warmup = "Laser se zapíná…"
        case waiting = "Čekám na cíl"
        case lure = "Láká"
        case flee = "Utíká"
        case freeze = "Zamrzla"
        case dash = "Prchá"
        case letCatch = "Nechá se chytit"
        case caught = "Chycena!"
        case ending = "Konec hry"
    }

    // MARK: Published state
    @Published private(set) var running = false
    @Published private(set) var preparing = false
    @Published private(set) var countdown = 0
    @Published private(set) var mode: Mode = .off
    @Published private(set) var escapes = 0
    @Published private(set) var catches = 0
    @Published private(set) var remaining: Double = 0
    @Published private(set) var dot = CGPoint(x: 200, y: 200)
    @Published var message = ""

    // MARK: Game settings (persisted)
    @Published var intensity = storedDouble("prey.intensity", 0.6) {
        didSet { UserDefaults.standard.set(intensity, forKey: "prey.intensity") }
    }
    @Published var sessionMinutes = storedDouble("prey.minutes", 5) {
        didSet { UserDefaults.standard.set(sessionMinutes, forKey: "prey.minutes") }
    }
    /// Average number of escapes before the dot lets itself be caught.
    @Published var catchEvery = storedDouble("prey.catchEvery", 4) {
        didSet { UserDefaults.standard.set(catchEvery, forKey: "prey.catchEvery") }
    }
    /// Keep the dot off the target.
    @Published var avoidCat = storedBool("prey.avoidCat", true) {
        didSet { UserDefaults.standard.set(avoidCat, forKey: "prey.avoidCat") }
    }
    /// Switch the laser off when the target leaves the view.
    @Published var autoOffWhenLost = storedBool("prey.autoOff", true) {
        didSet { UserDefaults.standard.set(autoOffWhenLost, forKey: "prey.autoOff") }
    }

    // MARK: Start-sequence settings (persisted)
    @Published var countdownSeconds = storedDouble("start.countdown", 5) {
        didSet { UserDefaults.standard.set(countdownSeconds, forKey: "start.countdown") }
    }
    @Published var calibrateBeforeGame = storedBool("start.calibrate", true) {
        didSet { UserDefaults.standard.set(calibrateBeforeGame, forKey: "start.calibrate") }
    }
    /// Length of the laser's own intro animation after power-on.
    @Published var warmupSeconds = storedDouble("laser.warmup", 5.5) {
        didSet { UserDefaults.standard.set(warmupSeconds, forKey: "laser.warmup") }
    }
    /// Wait at each calibration point before taking frames.
    @Published var settleSeconds = storedDouble("calib.settle", 1.5) {
        didSet { UserDefaults.standard.set(settleSeconds, forKey: "calib.settle") }
    }
    /// Exposure bias during calibration (EV). Negative = darker, helps in bright rooms.
    @Published var exposureBias = storedDouble("calib.exposure", -1.5) {
        didSet { UserDefaults.standard.set(exposureBias, forKey: "calib.exposure") }
    }

    private let laser: LaserController
    private let field: FieldModel
    private let camera: CameraManager

    private var timer: Timer?
    private var flowCancelled = false
    private var lastTick: CFTimeInterval = 0
    private var endTime: CFTimeInterval = 0
    private var modeStart: CFTimeInterval = 0
    private var modeDuration: Double = 0
    private var warmupUntil: CFTimeInterval = 0
    private var modeAfterWarmup: Mode = .waiting
    private var p = CGPoint(x: 200, y: 200)
    private var lastSent = CGPoint(x: -100, y: -100)
    private var lastCatSeen: CFTimeInterval = 0
    private var lureDir = CGPoint(x: 1, y: 0)
    private var tangentSign: CGFloat = 1
    private var nextCatchAt = 4
    private var dashTarget = CGPoint(x: 200, y: 200)
    private var wanderTarget = CGPoint(x: 200, y: 200)

    private let lostTimeout: Double = 2.5

    init(laser: LaserController, field: FieldModel, camera: CameraManager) {
        self.laser = laser
        self.field = field
        self.camera = camera
    }

    // MARK: - Start sequence: countdown → calibration → game

    @MainActor
    func startFlow() async {
        guard laser.isReady else { message = "Laser není připojený."; return }
        guard !running && !preparing else { return }
        message = ""
        flowCancelled = false
        preparing = true
        defer {
            preparing = false
            countdown = 0
        }

        var n = Int(countdownSeconds.rounded())
        while n > 0 {
            countdown = n
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if flowCancelled { message = "Start zrušen."; return }
            n -= 1
        }
        countdown = 0

        if calibrateBeforeGame || !field.isCalibrated {
            let ok = await field.calibrate(laser: laser, camera: camera, settle: settleSeconds,
                                           warmup: warmupSeconds, exposureBias: Float(exposureBias))
            if flowCancelled { message = "Start zrušen."; return }
            guard ok else {
                message = field.calibrationStatus
                return
            }
        }
        start()
    }

    func cancelFlow() {
        flowCancelled = true
        field.cancelRequested = true
    }

    /// Starts the game immediately with the current calibration.
    func start() {
        guard laser.isReady else { message = "Laser není připojený."; return }
        guard field.isCalibrated else { message = "Chybí kalibrace."; return }
        laser.pattern = .none
        if laser.preset != 0 { laser.setPreset(0) }
        escapes = 0
        catches = 0
        scheduleNextCatch()
        p = field.constrain(field.playCenter)
        lastSent = CGPoint(x: -100, y: -100)
        lastCatSeen = 0
        endTime = CACurrentMediaTime() + sessionMinutes * 60
        remaining = sessionMinutes * 60
        running = true
        camera.refreshDetectionSettings()
        setMode(.waiting)
        if !laser.laserOn { turnLaserOn(thenMode: .waiting) }
        laser.addLog("Hra: start (\(Int(sessionMinutes)) min, intenzita \(Int(intensity * 100)) %, cíl \(camera.target.title))")
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop(reason: String = "zastaveno") {
        cancelFlow()
        timer?.invalidate()
        timer = nil
        if running {
            laser.addLog("Hra: konec (\(reason)), útěků \(escapes), chycení \(catches)")
            if laser.isReady && laser.laserOn { laser.setLaser(false) }
        }
        running = false
        mode = .off
    }

    // MARK: - Main loop

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.1, max(0.001, now - lastTick)))
        lastTick = now
        guard running else { return }
        guard laser.isReady else {
            stop(reason: "laser se odpojil")
            message = "Laser se odpojil."
            return
        }

        remaining = max(0, endTime - now)

        // Laser intro animation after power-on – don't send moves, it would fight the animation.
        if mode == .warmup {
            if now >= warmupUntil { setMode(modeAfterWarmup) } else { return }
        }

        if remaining == 0 && mode != .ending && mode != .caught {
            setMode(.ending)
            laser.addLog("Hra: čas vypršel – tečka se nechá chytit")
        }

        var cat: CatState?
        if let c = field.cat, now - c.time < lostTimeout {
            cat = c
            if now - c.time < 0.4 { lastCatSeen = now }
        }

        guard let c = cat else {
            noCat(now: now, dt: dt)
            return
        }

        if !laser.laserOn {
            turnLaserOn(thenMode: .lure)
            return
        }

        let s = max(25, c.size)
        let fleeTrigger = s * CGFloat(2.0 + 0.8 * intensity)

        if mode == .waiting {
            setMode(.lure)
            lureDir = (field.playCenter - c.position).normalized
            if lureDir == .zero { lureDir = CGPoint(x: 1, y: 0) }
        }

        let lead = CGFloat(min(0.5, (now - c.time) + laser.estimatedLatency + 0.08))
        let catPos = c.position + c.velocity * lead
        let toDot = p - catPos
        let d = toDot.length
        let dirAway = d > 1 ? toDot * (1 / d) : lureDir
        let approach = c.velocity.dot(dirAway) // > 0 = target moving towards the dot

        let maxSpeed = CGFloat(120 + 480 * intensity)
        let lureSpeed = maxSpeed * 0.35
        let safeDist = s * 4.5
        let catchRadius = s * 0.75
        let elapsed = now - modeStart

        switch mode {
        case .off, .waiting, .warmup:
            break

        case .lure:
            lureDir = (lureDir * 0.97 + (field.playCenter - catPos).normalized * 0.03).normalized
            if lureDir == .zero { lureDir = CGPoint(x: 1, y: 0) }
            let wiggle = lureDir.perp * (sin(CGFloat(now) * 9) * s * 0.25)
            let target = catPos + lureDir * (fleeTrigger * 1.35) + wiggle
            moveTowards(target, speed: lureSpeed, dt: dt)
            if d < fleeTrigger || approach > s * 2.5 {
                if escapes >= nextCatchAt {
                    setMode(.letCatch)
                } else {
                    startFlee()
                }
            }

        case .flee:
            var dir = dirAway + dirAway.perp * (0.6 * tangentSign)
            let edge = field.distanceToEdge(p)
            if edge < s * 1.2 {
                let w = 1 - edge / (s * 1.2)
                dir = dir + (field.playCenter - p).normalized * (1.6 * w)
            }
            if Double.random(in: 0..<1) < Double(dt) * 0.8 { tangentSign *= -1 }
            let urgency = max(0.5, min(1.2, 0.5 + (fleeTrigger - d) / fleeTrigger))
            let before = p
            let wanted = dir.normalized * (maxSpeed * urgency * dt)
            p = field.constrain(p + wanted)
            if wanted.length > 1, (p - before).length < wanted.length * 0.3 {
                tangentSign *= -1 // stuck at the edge – turn the other way
            }
            if d > safeDist || elapsed > 3.5 {
                escapes += 1
                let r = Double.random(in: 0..<1)
                if r < 0.15 {
                    dashTarget = field.randomPoint(farFrom: catPos)
                    setMode(.dash)
                } else if r < 0.5 {
                    setMode(.freeze, duration: Double.random(in: 0.6...1.8))
                } else {
                    setMode(.lure)
                }
            }

        case .freeze:
            let twitch = CGPoint(x: CGFloat.random(in: -1...1), y: CGFloat.random(in: -1...1)) * (s * 0.04)
            p = field.constrain(p + twitch)
            if d < fleeTrigger * 0.8 || approach > s * 3 {
                startFlee()
            } else if elapsed > modeDuration {
                setMode(.lure)
            }

        case .dash:
            moveTowards(dashTarget, speed: maxSpeed * 1.6, dt: dt)
            if p.distance(to: dashTarget) < 4 || elapsed > 2 {
                setMode(.freeze, duration: Double.random(in: 0.4...1.0))
            }

        case .letCatch, .ending:
            let slow = mode == .ending ? lureSpeed * 0.3 : lureSpeed * 0.4
            let target = catPos + dirAway * (s * 0.9)
            moveTowards(target, speed: slow, dt: dt)
            if d < catchRadius {
                catches += 1
                setMode(.caught, duration: Double.random(in: 1.2...2.0))
            } else if mode == .letCatch && elapsed > 6 {
                scheduleNextCatch() // not interested – try again later
                setMode(.lure)
            } else if mode == .ending && elapsed > 12 {
                finish()
                return
            }

        case .caught:
            // Stay still "under the paw" (with the safety on: just in front of it).
            if elapsed > modeDuration {
                if remaining == 0 {
                    finish()
                    return
                }
                scheduleNextCatch()
                startFlee()
            }
        }

        if avoidCat {
            p = keepOffCat(p, cat: c, catPos: catPos, s: s)
        }
        p = field.constrain(p)
        sendIfMoved()
    }

    private func noCat(now: CFTimeInterval, dt: CGFloat) {
        let lostFor = now - lastCatSeen
        if mode == .ending {
            finish()
            return
        }
        if autoOffWhenLost {
            if lostFor > lostTimeout && laser.laserOn {
                laser.addLog("Hra: cíl zmizel ze záběru – laser vypnut")
                laser.setLaser(false)
            }
            if mode != .waiting { setMode(.waiting) }
            return
        }
        // Safety off: wander slowly to attract the cat back.
        if mode != .waiting { setMode(.waiting) }
        if !laser.laserOn {
            turnLaserOn(thenMode: .waiting)
            return
        }
        if p.distance(to: wanderTarget) < 10 {
            wanderTarget = field.randomPoint(farFrom: p)
        }
        moveTowards(wanderTarget, speed: CGFloat(60 + 120 * intensity), dt: dt)
        sendIfMoved()
    }

    // MARK: - Helpers

    private func turnLaserOn(thenMode m: Mode) {
        laser.setLaser(true)
        warmupUntil = CACurrentMediaTime() + warmupSeconds
        modeAfterWarmup = m
        setMode(.warmup)
        lastSent = CGPoint(x: -100, y: -100) // re-send position after the intro
    }

    private func startFlee() {
        tangentSign = Bool.random() ? 1 : -1
        setMode(.flee)
    }

    private func finish() {
        stop(reason: "konec hry")
        message = "Hra skončila – teď je čas na pamlsek nebo opravdovou hračku."
    }

    private func setMode(_ m: Mode, duration: Double = 0) {
        mode = m
        modeStart = CACurrentMediaTime()
        modeDuration = duration
    }

    private func scheduleNextCatch() {
        let base = max(1, Int(catchEvery.rounded()))
        nextCatchAt = escapes + max(1, base + Int.random(in: -1...1))
    }

    private func moveTowards(_ target: CGPoint, speed: CGFloat, dt: CGFloat) {
        let delta = target - p
        let step = speed * dt
        if delta.length <= step {
            p = target
        } else {
            p = p + delta.normalized * step
        }
        p = field.constrain(p)
    }

    private func keepOffCat(_ point: CGPoint, cat: CatState, catPos: CGPoint, s: CGFloat) -> CGPoint {
        let shift = catPos - cat.position
        let poly = cat.polygon.map { $0 + shift }
        let minDist = s * 0.6
        var q = point
        if poly.count >= 3 && Poly.contains(poly, q) {
            let edge = Poly.closestPointOnBoundary(poly, q)
            let out = (edge - catPos).normalized
            q = edge + (out == .zero ? CGPoint(x: 1, y: 0) : out) * (s * 0.25)
        }
        let v = q - catPos
        if v.length < minDist {
            let dir = v.length > 0.5 ? v.normalized : lureDir
            q = catPos + dir * minDist
        }
        return q
    }

    private func sendIfMoved() {
        dot = p
        guard p.distance(to: lastSent) >= 1 else { return }
        lastSent = p
        laser.gameMove(x: Int(p.x.rounded()), y: Int(p.y.rounded()))
    }
}

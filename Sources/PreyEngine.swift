import Foundation
import CoreGraphics
import QuartzCore

/// Moves the laser dot like prey: lures the cat, flees, freezes, hides, lets itself be caught.
final class PreyEngine: ObservableObject {
    enum Mode: String {
        case off = "Vypnuto"
        case waiting = "Čekám na kočku"
        case lure = "Láká"
        case flee = "Utíká"
        case freeze = "Zamrzla"
        case hide = "Schovala se"
        case letCatch = "Nechá se chytit"
        case caught = "Chycena!"
        case ending = "Konec hry"
    }

    // MARK: Published state
    @Published private(set) var running = false
    @Published private(set) var mode: Mode = .off
    @Published private(set) var escapes = 0
    @Published private(set) var catches = 0
    @Published private(set) var remaining: Double = 0
    @Published private(set) var dot = CGPoint(x: 200, y: 200)
    @Published var message = ""

    // MARK: Settings (persisted)
    @Published var intensity: Double = UserDefaults.standard.object(forKey: "prey.intensity") as? Double ?? 0.6 {
        didSet { UserDefaults.standard.set(intensity, forKey: "prey.intensity") }
    }
    @Published var sessionMinutes: Double = UserDefaults.standard.object(forKey: "prey.minutes") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(sessionMinutes, forKey: "prey.minutes") }
    }
    /// Average number of escapes before the dot lets itself be caught.
    @Published var catchEvery: Double = UserDefaults.standard.object(forKey: "prey.catchEvery") as? Double ?? 4 {
        didSet { UserDefaults.standard.set(catchEvery, forKey: "prey.catchEvery") }
    }
    /// Never put the dot onto the cat.
    @Published var avoidCat: Bool = UserDefaults.standard.object(forKey: "prey.avoidCat") as? Bool ?? true {
        didSet { UserDefaults.standard.set(avoidCat, forKey: "prey.avoidCat") }
    }
    /// Switch the laser off when the cat leaves the view.
    @Published var autoOffWhenLost: Bool = UserDefaults.standard.object(forKey: "prey.autoOff") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoOffWhenLost, forKey: "prey.autoOff") }
    }

    private let laser: LaserController
    private let field: FieldModel

    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0
    private var endTime: CFTimeInterval = 0
    private var modeStart: CFTimeInterval = 0
    private var modeDuration: Double = 0
    private var p = CGPoint(x: 200, y: 200)
    private var lastSent = CGPoint(x: -100, y: -100)
    private var laserWanted = false
    private var lastCatSeen: CFTimeInterval = 0
    private var lureDir = CGPoint(x: 1, y: 0)
    private var tangentSign: CGFloat = 1
    private var nextCatchAt = 4
    private var hideTarget = CGPoint(x: 200, y: 200)
    private var wanderTarget = CGPoint(x: 200, y: 200)

    private let lostTimeout: Double = 2.5

    init(laser: LaserController, field: FieldModel) {
        self.laser = laser
        self.field = field
    }

    // MARK: - Control

    func start() {
        guard laser.isReady else { message = "Laser není připojený (záložka Test)."; return }
        guard field.isCalibrated else { message = "Nejdřív proveď kalibraci."; return }
        message = ""
        laser.pattern = .none
        if laser.preset != 0 { laser.setPreset(0) }
        escapes = 0
        catches = 0
        scheduleNextCatch()
        p = field.constrain(field.playCenter)
        lastSent = CGPoint(x: -100, y: -100)
        laserWanted = false
        lastCatSeen = 0
        endTime = CACurrentMediaTime() + sessionMinutes * 60
        remaining = sessionMinutes * 60
        running = true
        setMode(.waiting)
        laser.addLog("Hra: start (\(Int(sessionMinutes)) min, intenzita \(Int(intensity * 100)) %)")
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop(reason: String = "zastaveno") {
        timer?.invalidate()
        timer = nil
        if running { laser.addLog("Hra: konec (\(reason)), útěků \(escapes), chycení \(catches)") }
        running = false
        setLaserWanted(false)
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
        if remaining == 0 && mode != .ending && mode != .caught {
            setMode(.ending)
            laser.addLog("Hra: čas vypršel – tečka se nechá chytit a zhasne")
        }

        // Cat state (with prediction for system latency)
        var cat: CatState?
        if let c = field.cat, now - c.time < lostTimeout {
            cat = c
            if now - c.time < 0.4 { lastCatSeen = now }
        }

        guard let c = cat else {
            noCat(now: now, dt: dt)
            return
        }

        if mode == .waiting {
            setMode(.lure)
            lureDir = (field.playCenter - c.position).normalized
            if lureDir == .zero { lureDir = CGPoint(x: 1, y: 0) }
            p = field.constrain(c.position + lureDir * (max(25, c.size) * 3.8))
        }

        let lead = CGFloat(min(0.5, (now - c.time) + laser.estimatedLatency + 0.08))
        let catPos = c.position + c.velocity * lead
        let s = max(25, c.size)
        let toDot = p - catPos
        let d = toDot.length
        let dirAway = d > 1 ? toDot * (1 / d) : lureDir
        let approach = c.velocity.dot(dirAway) // > 0 = cat moving towards the dot

        let maxSpeed = CGFloat(120 + 480 * intensity)
        let lureSpeed = maxSpeed * 0.35
        let fleeTrigger = s * CGFloat(2.0 + 0.8 * intensity)
        let safeDist = s * 4.5
        let catchRadius = s * 0.75
        let elapsed = now - modeStart

        var showLaser = true

        switch mode {
        case .off, .waiting:
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
                    hideTarget = field.randomPoint(farFrom: catPos)
                    setMode(.hide, duration: Double.random(in: 0.6...1.4))
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

        case .hide:
            showLaser = false
            moveTowards(hideTarget, speed: maxSpeed * 1.5, dt: dt)
            if elapsed > modeDuration {
                setMode(.freeze, duration: Double.random(in: 0.3...0.8))
            }

        case .letCatch, .ending:
            // Slow down and wait for the cat to pounce.
            let slow = mode == .ending ? lureSpeed * 0.3 : lureSpeed * 0.4
            let target = catPos + dirAway * (s * 0.9)
            moveTowards(target, speed: slow, dt: dt)
            if d < catchRadius {
                catches += 1
                setMode(.caught, duration: Double.random(in: 1.2...2.0))
            } else if mode == .letCatch && elapsed > 6 {
                scheduleNextCatch() // cat not interested – try again later
                setMode(.lure)
            } else if mode == .ending && elapsed > 12 {
                finish()
                return
            }

        case .caught:
            // "Caught under the paw": with the cat-safety on, the dot disappears instead of shining on the cat.
            showLaser = !avoidCat
            if elapsed > modeDuration {
                if remaining == 0 {
                    finish()
                    return
                }
                scheduleNextCatch()
                p = field.constrain(catPos + lureDir * (s * 1.5))
                startFlee()
            }
        }

        // Safety: never put the dot onto the cat.
        if avoidCat && showLaser {
            p = keepOffCat(p, cat: c, catPos: catPos, s: s)
        }

        p = field.constrain(p)

        // If the fence pushed the dot back onto the cat (cat in a corner), hide it rather than shine on the cat.
        if avoidCat && showLaser {
            let poly = c.polygon.map { $0 + (catPos - c.position) }
            if (poly.count >= 3 && Poly.contains(poly, p)) || p.distance(to: catPos) < s * 0.3 {
                showLaser = false
            }
        }

        setLaserWanted(showLaser)
        sendIfMoved()
    }

    private func noCat(now: CFTimeInterval, dt: CGFloat) {
        let lostFor = now - lastCatSeen
        if mode == .ending {
            finish()
            return
        }
        if autoOffWhenLost {
            if mode != .waiting {
                laser.addLog("Hra: kočka zmizela ze záběru – laser vypnut")
                setMode(.waiting)
            }
            setLaserWanted(false)
            return
        }
        // Safety off: wander slowly to attract the cat.
        if mode != .waiting && lostFor > lostTimeout { setMode(.waiting) }
        if p.distance(to: wanderTarget) < 10 {
            wanderTarget = field.randomPoint(farFrom: p)
        }
        moveTowards(wanderTarget, speed: CGFloat(60 + 120 * intensity), dt: dt)
        p = field.constrain(p)
        setLaserWanted(true)
        sendIfMoved()
    }

    // MARK: - Helpers

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

    private func setLaserWanted(_ on: Bool) {
        guard on != laserWanted || on != laser.laserOn else { return }
        laserWanted = on
        if laser.isReady && laser.laserOn != on {
            laser.setLaser(on)
        }
    }

    private func sendIfMoved() {
        dot = p
        guard p.distance(to: lastSent) >= 1 else { return }
        lastSent = p
        laser.gameMove(x: Int(p.x.rounded()), y: Int(p.y.rounded()))
    }
}

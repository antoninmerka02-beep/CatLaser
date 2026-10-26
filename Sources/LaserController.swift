import Foundation
import CoreBluetooth
import QuartzCore

/// Device credentials from Tuya IoT Platform ("Query Device Details").
struct Credentials {
    var deviceId: String
    var localKey: String
    var uuid: String

    static let deviceIdKey = "deviceId"
    static let localKeyKey = "localKey"
    static let uuidKey = "uuid"

    static func load() -> Credentials? {
        let d = UserDefaults.standard
        let c = Credentials(
            deviceId: (d.string(forKey: deviceIdKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            localKey: d.string(forKey: localKeyKey) ?? "",
            uuid: (d.string(forKey: uuidKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard !c.deviceId.isEmpty, c.localKey.count >= 6, !c.uuid.isEmpty else { return nil }
        return c
    }

    /// Accepts the JSON returned by "Query Device Details" (or just the inner object).
    static func parse(json text: String) -> Credentials? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var dict: [String: Any] = obj
        if let arr = obj["result"] as? [[String: Any]], let first = arr.first { dict = first }
        else if let r = obj["result"] as? [String: Any] { dict = r }
        guard let id = dict["id"] as? String,
              let key = dict["local_key"] as? String,
              let uuid = dict["uuid"] as? String else { return nil }
        return Credentials(deviceId: id, localKey: key, uuid: uuid)
    }
}

/// Laser Dot datapoints (from "Query Things Data Model").
enum LaserDP {
    static let timing: UInt8 = 101   // raw: [year-2000, month, day, hour, minute, second]
    static let move: UInt8 = 102     // raw: X hi, X lo, Y hi, Y lo – range 0…400, centre (200, 200)
    static let schedule: UInt8 = 103 // raw – not used
    static let preset: UInt8 = 104   // value: 0 = stop, 1/2/3 = small/medium/large
    static let laser: UInt8 = 105    // bool: laser on/off
    // 106 = factory reset of the MCU – NEVER sent by this app
    static let version: UInt8 = 107  // raw, read only
}

final class LaserController: NSObject, ObservableObject {
    enum ConnState: String {
        case idle = "Nepřipojeno"
        case scanning = "Hledám laser…"
        case connecting = "Připojuji…"
        case handshake = "Ověřuji spojení…"
        case ready = "Připojeno"
        case failed = "Chyba"
    }

    enum TestPattern: String, CaseIterable, Identifiable {
        case none = "Vyp"
        case circle = "Kruh"
        case sweep = "Tam a zpět"
        case jumps = "Skoky"
        var id: String { rawValue }
    }

    static let svcAdv = CBUUID(string: "A201")
    static let svcData = CBUUID(string: "1910")
    static let chNotify = CBUUID(string: "2B10")
    static let chWrite = CBUUID(string: "2B11")

    // MARK: Published state
    @Published var state: ConnState = .idle
    @Published var statusDetail = ""
    @Published var deviceInfo = ""
    @Published var laserOn = false
    @Published var preset = 0
    @Published var targetX = 200
    @Published var targetY = 200
    @Published var lastRtt: Double?
    @Published var avgRtt: Double?
    @Published var maxRtt: Double?
    @Published var movesSent = 0
    @Published var movesAcked = 0
    @Published var movesLost = 0
    @Published var log: [String] = []
    @Published var verboseLog = false
    @Published var waitForAck = true
    @Published var minIntervalMs: Double = 30
    @Published var patternSpeed: Double = 0.5
    @Published var pattern: TestPattern = .none {
        didSet { if oldValue != pattern { patternChanged() } }
    }

    var isReady: Bool { state == .ready }

    // MARK: Private
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var session: TuyaSession?
    private var creds: Credentials?
    private var wantConnect = false
    private var outQueue: [Data] = []
    private var advProtocolVersion: UInt8 = 3
    private var skippedPeripherals = Set<UUID>()

    private var pendingRequests: [UInt32: (kind: String, sent: CFTimeInterval)] = [:]
    private var moveInFlightSeq: UInt32?
    private var lastMoveSentAt: CFTimeInterval = 0
    private var pendingMove: (x: Int, y: Int)?
    private var moveRetryScheduled = false
    private var rttSamples: [Double] = []
    private var patternTimer: Timer?
    private var patternStart: CFTimeInterval = 0
    private var timeoutWork: DispatchWorkItem?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API

    func connect() {
        guard let c = Credentials.load() else {
            fail("Chybí údaje – vyplň je v Nastavení (ozubené kolo vpravo nahoře).")
            return
        }
        creds = c
        wantConnect = true
        skippedPeripherals = []
        session = TuyaSession(localKey: c.localKey)
        statusDetail = ""
        addLog("Připojuji k zařízení \(c.deviceId) (uuid \(c.uuid))")
        if central.state == .poweredOn {
            startDiscovery()
        } else {
            addLog("Čekám na Bluetooth…")
        }
    }

    func disconnect() {
        wantConnect = false
        central.stopScan()
        cancelTimeout()
        pattern = .none
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        resetLink()
        peripheral = nil
        state = .idle
        addLog("Odpojeno uživatelem")
    }

    func setLaser(_ on: Bool) {
        if sendDp(LaserDP.laser, .bool, [on ? 1 : 0], kind: "laser \(on ? "ON" : "OFF")") != nil {
            laserOn = on
        }
    }

    func setPreset(_ n: Int) {
        if n != 0 { pattern = .none }
        if sendDp(LaserDP.preset, .value, int32BE(n), kind: "preset \(n)") != nil {
            preset = n
        }
    }

    func syncTime() {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let bytes: [UInt8] = [
            UInt8(((c.year ?? 2000) - 2000) & 0xff),
            UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0)
        ]
        sendDp(LaserDP.timing, .raw, bytes, kind: "čas")
    }

    func requestStatus() {
        guard isReady else { return }
        send(.deviceStatus, [], kind: "status")
    }

    /// Manual move from the joystick pad (stops any running test pattern).
    func userMove(x: Int, y: Int) {
        if pattern != .none { pattern = .none }
        queueMove(x: x, y: y)
    }

    func centre() { userMove(x: 200, y: 200) }

    /// Move requested by the game / calibration (does not touch test patterns).
    func gameMove(x: Int, y: Int) {
        queueMove(x: x, y: y)
    }

    /// Estimated one-way command latency in seconds (half of the average ack round trip, min 40 ms).
    var estimatedLatency: Double {
        max(0.04, (avgRtt ?? 80) / 2000)
    }

    func resetStats() {
        rttSamples = []
        lastRtt = nil
        avgRtt = nil
        maxRtt = nil
        movesSent = 0
        movesAcked = 0
        movesLost = 0
    }

    func clearLog() { log = [] }

    // MARK: - Moves

    private func queueMove(x: Int, y: Int) {
        let cx = max(0, min(400, x))
        let cy = max(0, min(400, y))
        targetX = cx
        targetY = cy
        pendingMove = (cx, cy)
        trySendMove()
    }

    private func trySendMove() {
        guard isReady, let m = pendingMove else { return }
        let now = CACurrentMediaTime()

        if let inflight = moveInFlightSeq, waitForAck {
            let elapsed = now - lastMoveSentAt
            if elapsed < 0.5 {
                scheduleMoveRetry(0.5 - elapsed)
                return
            }
            pendingRequests.removeValue(forKey: inflight)
            moveInFlightSeq = nil
            movesLost += 1
            addLog("⚠️ Potvrzení pohybu #\(inflight) nepřišlo do 500 ms")
        }

        let wait = minIntervalMs / 1000 - (now - lastMoveSentAt)
        if wait > 0 {
            scheduleMoveRetry(wait)
            return
        }

        pendingMove = nil
        let payload: [UInt8] = [UInt8((m.x >> 8) & 0xff), UInt8(m.x & 0xff), UInt8((m.y >> 8) & 0xff), UInt8(m.y & 0xff)]
        if let seq = sendDp(LaserDP.move, .raw, payload, kind: "move", quiet: true) {
            moveInFlightSeq = seq
            lastMoveSentAt = now
            movesSent += 1
        }
    }

    private func scheduleMoveRetry(_ delay: Double) {
        guard !moveRetryScheduled else { return }
        moveRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, delay)) { [weak self] in
            guard let self = self else { return }
            self.moveRetryScheduled = false
            self.trySendMove()
        }
    }

    private func recordRtt(_ ms: Double) {
        rttSamples.append(ms)
        if rttSamples.count > 50 { rttSamples.removeFirst(rttSamples.count - 50) }
        lastRtt = ms
        avgRtt = rttSamples.reduce(0, +) / Double(rttSamples.count)
        maxRtt = rttSamples.max()
    }

    // MARK: - Test patterns

    private func patternChanged() {
        patternTimer?.invalidate()
        patternTimer = nil
        guard pattern != .none else { return }
        guard isReady else {
            addLog("Testovací vzor: nejdřív se připoj")
            DispatchQueue.main.async { self.pattern = .none }
            return
        }
        if preset != 0 { setPreset(0) }
        patternStart = CACurrentMediaTime()
        addLog("Testovací vzor: \(pattern.rawValue)")
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.patternTick() }
        RunLoop.main.add(t, forMode: .common)
        patternTimer = t
    }

    private func patternTick() {
        let t = CACurrentMediaTime() - patternStart
        switch pattern {
        case .none:
            return
        case .circle:
            let a = 2 * Double.pi * patternSpeed * t
            queueMove(x: 200 + Int(130 * cos(a)), y: 200 + Int(130 * sin(a)))
        case .sweep:
            let phase = (t * patternSpeed).truncatingRemainder(dividingBy: 1)
            let tri = phase < 0.5 ? phase * 2 : 2 - phase * 2
            queueMove(x: 40 + Int(320 * tri), y: 200)
        case .jumps:
            let half = Int(t * patternSpeed * 2) % 2
            queueMove(x: half == 0 ? 80 : 320, y: 200)
        }
    }

    // MARK: - Connection flow

    private func startDiscovery() {
        state = .scanning
        let already = central.retrieveConnectedPeripherals(withServices: [Self.svcData, Self.svcAdv])
        if let p = already.first {
            addLog("Laser už je připojený v systému (\(p.name ?? "?")) – použiji toto spojení")
            connectTo(p)
            return
        }
        central.scanForPeripherals(withServices: [Self.svcAdv], options: nil)
        scheduleTimeout(15, "Laser nenalezen. Je zapnutý a není právě připojený v Smart Life / Tesla aplikaci?")
    }

    private func connectTo(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
        scheduleTimeout(10, "Připojení se nepodařilo (timeout).")
    }

    private func startHandshake() {
        guard let s = session else { return }
        state = .handshake
        s.reset()
        s.protocolVersion = advProtocolVersion
        outQueue = []
        pendingRequests = [:]
        moveInFlightSeq = nil
        addLog("Posílám DEVICE_INFO (login key)")
        send(.deviceInfo, [], kind: "deviceInfo")
        scheduleTimeout(8, "Laser neodpověděl na handshake. Nejčastěji špatný local_key, nebo je laser připojený v jiné aplikaci.")
    }

    private func handleDeviceInfo(_ data: [UInt8]) {
        guard let s = session, let c = creds else { return }
        do {
            try s.applyDeviceInfo(data)
        } catch {
            fail("Chybná odpověď DEVICE_INFO: \(error)")
            return
        }
        deviceInfo = "FW \(data[0]).\(data[1]) · protokol \(data[2]).\(data[3]) · HW \(data[12]).\(data[13]) · bound \(data[5])"
        addLog("DEVICE_INFO: \(deviceInfo)")
        addLog("Posílám PAIR (session key)")
        send(.pair, s.pairingRequest(uuid: c.uuid, deviceId: c.deviceId), kind: "pair")
    }

    private func handlePair(_ data: [UInt8]) {
        let r = data.first ?? 255
        guard r == 0 || r == 2 else {
            fail("Párování odmítnuto (kód \(r)). Zkontroluj device ID, uuid a local_key.")
            return
        }
        cancelTimeout()
        state = .ready
        statusDetail = ""
        addLog("✅ Spárováno\(r == 2 ? " (už bylo spárované)" : "") – laser je připraven")
        send(.deviceStatus, [], kind: "status")
    }

    private func fail(_ msg: String) {
        addLog("❌ " + msg)
        statusDetail = msg
        state = .failed
        wantConnect = false
        cancelTimeout()
        central.stopScan()
        pattern = .none
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
    }

    private func resetLink() {
        writeChar = nil
        notifyChar = nil
        outQueue = []
        pendingRequests = [:]
        moveInFlightSeq = nil
        pendingMove = nil
        session?.reset()
        patternTimer?.invalidate()
        patternTimer = nil
    }

    private func scheduleTimeout(_ seconds: Double, _ msg: String) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.fail(msg) }
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func cancelTimeout() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    // MARK: - Sending

    @discardableResult
    private func sendDp(_ id: UInt8, _ type: DPType, _ value: [UInt8], kind: String, quiet: Bool = false) -> UInt32? {
        guard isReady else {
            addLog("Nejdřív se připoj k laseru")
            return nil
        }
        let payload = TuyaSession.encodeDPs([TuyaDP(id: id, type: type.rawValue, value: value)])
        return send(.sendDps, payload, kind: kind, quiet: quiet)
    }

    @discardableResult
    private func send(_ code: TuyaCode, _ data: [UInt8], responseTo: UInt32 = 0, kind: String? = nil, quiet: Bool = false) -> UInt32? {
        guard let s = session, writeChar != nil else { return nil }
        do {
            let built = try s.build(code: code, data: data, responseTo: responseTo)
            if let kind = kind {
                prunePending()
                pendingRequests[built.seq] = (kind, CACurrentMediaTime())
            }
            if !quiet || verboseLog {
                let resp = responseTo != 0 ? " ↩︎#\(responseTo)" : ""
                addLog("→ #\(built.seq) \(code)\(resp) \(data.isEmpty ? "" : data.hex)")
            }
            outQueue += built.packets.map { Data($0) }
            pump()
            return built.seq
        } catch {
            addLog("Chyba sestavení zprávy: \(error)")
            return nil
        }
    }

    private func prunePending() {
        let now = CACurrentMediaTime()
        pendingRequests = pendingRequests.filter { now - $0.value.sent < 5 }
    }

    private func pump() {
        guard let p = peripheral, let w = writeChar else { return }
        while !outQueue.isEmpty && p.canSendWriteWithoutResponse {
            p.writeValue(outQueue.removeFirst(), for: w, type: .withoutResponse)
        }
    }

    // MARK: - Receiving

    private func handle(_ msg: TuyaMessage) {
        let code = TuyaCode(rawValue: msg.code)

        if msg.responseTo != 0, let req = pendingRequests.removeValue(forKey: msg.responseTo) {
            let rtt = (CACurrentMediaTime() - req.sent) * 1000
            switch req.kind {
            case "deviceInfo":
                handleDeviceInfo(msg.data)
            case "pair":
                handlePair(msg.data)
            case "move":
                recordRtt(rtt)
                movesAcked += 1
                if moveInFlightSeq == msg.responseTo { moveInFlightSeq = nil }
                if verboseLog { addLog("← ✓ move #\(msg.responseTo) \(Int(rtt)) ms") }
                trySendMove()
            default:
                addLog("← ✓ \(req.kind) potvrzeno za \(Int(rtt)) ms\(msg.data.isEmpty ? "" : " [\(msg.data.hex)]")")
            }
            return
        }

        if verboseLog || code == nil {
            addLog("← #\(msg.seq) \(msg.codeName)\(msg.responseTo != 0 ? " ↩︎#\(msg.responseTo)" : "") \(msg.data.hex)")
        }

        guard let c = code else { return }
        let d = msg.data
        switch c {
        case .receiveDp:
            applyDPs(TuyaSession.parseDPs(d, from: 0))
            send(.receiveDp, [], responseTo: msg.seq, quiet: true)

        case .receiveTimeDp:
            let pos = timestampEnd(d, 0)
            applyDPs(TuyaSession.parseDPs(d, from: pos))
            send(.receiveTimeDp, [], responseTo: msg.seq, quiet: true)

        case .receiveSignDp:
            guard d.count >= 3 else { return }
            applyDPs(TuyaSession.parseDPs(d, from: 3))
            send(.receiveSignDp, [d[0], d[1], d[2], 0], responseTo: msg.seq, quiet: true)

        case .receiveSignTimeDp:
            guard d.count >= 3 else { return }
            let pos = timestampEnd(d, 3)
            applyDPs(TuyaSession.parseDPs(d, from: pos))
            send(.receiveSignTimeDp, [d[0], d[1], d[2], 0], responseTo: msg.seq, quiet: true)

        case .time1Req:
            let ms = Int64(Date().timeIntervalSince1970 * 1000)
            var resp = Array(String(ms).utf8)
            resp.appendBE16(UInt16(bitPattern: timezoneHundredths()))
            send(.time1Req, resp, responseTo: msg.seq, quiet: !verboseLog)
            addLog("Laser si vyžádal čas (TIME1) – odesláno")

        case .time2Req:
            let cal = Calendar.current
            let now = Date()
            let comp = cal.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: now)
            let wday = ((comp.weekday ?? 1) + 5) % 7 // Python tm_wday: Monday = 0
            var resp: [UInt8] = [
                UInt8((comp.year ?? 2000) % 100), UInt8(comp.month ?? 1), UInt8(comp.day ?? 1),
                UInt8(comp.hour ?? 0), UInt8(comp.minute ?? 0), UInt8(comp.second ?? 0), UInt8(wday)
            ]
            resp.appendBE16(UInt16(bitPattern: timezoneHundredths()))
            send(.time2Req, resp, responseTo: msg.seq, quiet: !verboseLog)
            addLog("Laser si vyžádal čas (TIME2) – odesláno")

        default:
            addLog("← nezpracovaná zpráva \(msg.codeName) \(d.hex)")
        }
    }

    private func timezoneHundredths() -> Int16 {
        Int16(TimeZone.current.secondsFromGMT() / 36)
    }

    private func timestampEnd(_ d: [UInt8], _ start: Int) -> Int {
        guard start < d.count else { return start }
        switch d[start] {
        case 0: return start + 1 + 13
        case 1: return start + 1 + 4
        default: return start + 1
        }
    }

    private func applyDPs(_ dps: [TuyaDP]) {
        for dp in dps {
            let typeName = DPType(rawValue: dp.type)?.name ?? "\(dp.type)"
            var desc = dp.value.hex
            switch dp.id {
            case LaserDP.laser:
                laserOn = (dp.value.first ?? 0) != 0
                desc = laserOn ? "ON" : "OFF"
            case LaserDP.preset:
                preset = Int(int32FromBE(dp.value))
                desc = "\(preset)"
            case LaserDP.move where dp.value.count >= 4:
                desc = "X \(Int(dp.value.be16(0))) Y \(Int(dp.value.be16(2)))"
            case LaserDP.version where dp.value.count >= 2:
                desc = "MCU v\(dp.value[0]).\(String(format: "%02d", Int(dp.value[1])))"
            default:
                break
            }
            if dp.id != LaserDP.move || verboseLog {
                addLog("← DP \(dp.id) (\(typeName)) = \(desc)")
            }
        }
    }

    // MARK: - Helpers

    private func int32BE(_ v: Int) -> [UInt8] {
        let u = UInt32(bitPattern: Int32(truncatingIfNeeded: v))
        var out: [UInt8] = []
        out.appendBE32(u)
        return out
    }

    private func int32FromBE(_ b: [UInt8]) -> Int32 {
        var v: UInt32 = 0
        for x in b.prefix(4) { v = (v << 8) | UInt32(x) }
        if b.count < 4 { return Int32(truncatingIfNeeded: Int(v)) }
        return Int32(bitPattern: v)
    }

    func addLog(_ s: String) {
        let line = "\(Self.timeFormatter.string(from: Date())) \(s)"
        log.append(line)
        if log.count > 600 { log.removeFirst(log.count - 600) }
    }
}

// MARK: - CBCentralManagerDelegate

extension LaserController: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            addLog("Bluetooth zapnutý")
            if wantConnect && peripheral == nil { startDiscovery() }
        case .unauthorized:
            fail("Aplikace nemá povolený Bluetooth (Nastavení → Soukromí → Bluetooth).")
        case .poweredOff:
            addLog("Bluetooth je vypnutý")
            if state != .idle { state = .failed; statusDetail = "Bluetooth je vypnutý" }
        default:
            addLog("Stav Bluetooth: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !skippedPeripherals.contains(peripheral.identifier) else { return }
        let mfg = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let sd = serviceData?[Self.svcAdv].map { [UInt8]($0) } ?? []

        // Tuya company ID 0x07D0 (little endian in the advertisement)
        guard mfg.count >= 4, mfg[0] == 0xD0, mfg[1] == 0x07 else { return }
        let body = Array(mfg.dropFirst(2))
        let advUuid = TuyaCrypto.advertisedUUID(serviceData: sd, manufacturerBody: body)
        addLog("Nalezeno: \(peripheral.name ?? "?") RSSI \(RSSI), uuid \(advUuid ?? "?"), protokol v\(body[1])")

        if let u = advUuid, let c = creds, u != c.uuid {
            addLog("…jiné Tuya zařízení, přeskakuji")
            skippedPeripherals.insert(peripheral.identifier)
            return
        }
        advProtocolVersion = body[1]
        connectTo(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        addLog("Připojeno přes BLE, hledám služby")
        peripheral.discoverServices([Self.svcData])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail("Připojení selhalo: \(error?.localizedDescription ?? "neznámá chyba")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        addLog("BLE odpojeno\(error.map { ": \($0.localizedDescription)" } ?? "")")
        resetLink()
        self.peripheral = nil
        if state != .failed && state != .idle {
            state = .failed
            statusDetail = "Spojení se přerušilo"
        }
        wantConnect = false
    }
}

// MARK: - CBPeripheralDelegate

extension LaserController: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.svcData }) else {
            fail("Služba 1910 nenalezena – je to opravdu Tuya laser?")
            return
        }
        peripheral.discoverCharacteristics([Self.chNotify, Self.chWrite], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        notifyChar = chars.first { $0.uuid == Self.chNotify }
        writeChar = chars.first { $0.uuid == Self.chWrite }
        guard let n = notifyChar, writeChar != nil else {
            fail("Charakteristiky 2B10/2B11 nenalezeny")
            return
        }
        peripheral.setNotifyValue(true, for: n)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            fail("Nepodařilo se zapnout notifikace: \(e.localizedDescription)")
            return
        }
        if characteristic.uuid == Self.chNotify && characteristic.isNotifying {
            startHandshake()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.chNotify, let v = characteristic.value, let s = session else { return }
        let bytes = [UInt8](v)
        if verboseLog { addLog("← raw \(bytes.hex)") }
        do {
            if let msg = try s.feed(bytes) {
                handle(msg)
            }
        } catch {
            addLog("Chyba příjmu: \(error)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pump()
    }
}

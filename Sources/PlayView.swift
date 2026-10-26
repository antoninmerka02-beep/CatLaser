import SwiftUI
import AVFoundation
import QuartzCore

struct PlayView: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    CameraStage()
                    LimitsCard()
                    FenceCard()
                    GameSettingsCard()
                    StartCard()
                    AdvancedCard()
                }
                .padding(16)
            }
            .scrollDisabled(field.editingFence)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Hra")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            camera.start()
        }
        .onDisappear {
            if !engine.running && !engine.preparing && !field.calibrating { camera.stop() }
        }
    }
}

// MARK: - Camera preview + overlay

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let v = PreviewUIView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ v: PreviewUIView, context: Context) {
        if let c = v.previewLayer.connection, c.isVideoOrientationSupported {
            c.videoOrientation = .portrait
        }
    }
}

struct CameraStage: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    @State private var dragIndex: Int?
    @State private var dragStarted = false

    var body: some View {
        ZStack {
            Color.black
            CameraPreview(session: camera.session)
            GeometryReader { geo in
                overlay(size: geo.size)
                    .contentShape(Rectangle())
                    .gesture(fenceGesture(size: geo.size))
                    .allowsHitTesting(field.editingFence)
            }
            if !camera.authorized {
                Text("Aplikace nemá přístup ke kameře.\nPovol ho v Nastavení iPhonu.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
            }
            if engine.countdown > 0 {
                VStack(spacing: 6) {
                    Text("\(engine.countdown)")
                        .font(.system(size: 72, weight: .bold, design: .rounded))
                    Text("Nesahej na telefon")
                        .font(.headline)
                }
                .foregroundStyle(.white)
                .shadow(radius: 6)
            }
        }
        .aspectRatio(camera.imageAspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.0f fps · detekce %.0f/s · cíl %.0f %%",
                        camera.fps, camera.detectFps, Double(camera.lastDetectionConfidence) * 100))
                .font(.system(size: 10, design: .monospaced))
                .padding(4)
                .background(Color.black.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
        .overlay(alignment: .bottom) {
            if engine.running || field.calibrating {
                Text(field.calibrating ? field.calibrationStatus : engine.mode.rawValue)
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(8)
            }
        }
        .frame(height: 460)
        .frame(maxWidth: .infinity)
    }

    private func overlay(size: CGSize) -> some View {
        let w = size.width, h = size.height
        let toView: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * w, y: $0.y * h) }
        let reach = (field.calibration?.reach ?? []).compactMap { field.laserToCamPoint($0) }.map(toView)
        let limits = field.isCalibrated ? field.limits.compactMap { field.laserToCamPoint($0) }.map(toView) : []
        let fence = field.fenceCam.map(toView)
        let editing = field.editingFence
        let now = CACurrentMediaTime()
        let cat = field.cat.flatMap { now - $0.time < 1.0 ? $0 : nil }
        let catRect = cat.map { CGRect(x: $0.rect.minX * w, y: $0.rect.minY * h, width: $0.rect.width * w, height: $0.rect.height * h) }
        let dotLaser = engine.running ? engine.dot : CGPoint(x: laser.targetX, y: laser.targetY)
        let dot = (field.isCalibrated && !field.calibrating) ? field.laserToCamPoint(dotLaser).map(toView) : nil
        let calibDots = field.calibrationDots.map(toView)
        let targetName = camera.target == .cat ? "kočka" : "člověk"

        return Canvas { ctx, _ in
            if limits.count >= 3 {
                var path = Path()
                path.addLines(limits)
                path.closeSubpath()
                ctx.stroke(path, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
            if reach.count >= 3 {
                var path = Path()
                path.addLines(reach)
                path.closeSubpath()
                ctx.stroke(path, with: .color(.cyan.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            if fence.count >= 2 {
                var path = Path()
                path.addLines(fence)
                if fence.count >= 3 { path.closeSubpath() }
                ctx.fill(path, with: .color(.yellow.opacity(0.08)))
                ctx.stroke(path, with: .color(.yellow), lineWidth: 2)
            }
            if editing {
                for (i, p) in fence.enumerated() {
                    let r = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
                    ctx.fill(Path(ellipseIn: r), with: .color(.yellow))
                    ctx.draw(Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundColor(.black), at: p)
                }
            }
            for c in calibDots {
                let r = CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12)
                ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
            }
            if let r = catRect {
                ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.green), lineWidth: 2)
                ctx.draw(Text(targetName).font(.system(size: 11, weight: .semibold)).foregroundColor(.green),
                         at: CGPoint(x: r.minX + 4, y: max(8, r.minY - 9)), anchor: .leading)
            }
            if let d = dot {
                let r = CGRect(x: d.x - 8, y: d.y - 8, width: 16, height: 16)
                ctx.stroke(Path(ellipseIn: r), with: .color(.red), lineWidth: 2.5)
                ctx.fill(Path(ellipseIn: r.insetBy(dx: 5, dy: 5)), with: .color(.red))
            }
        }
    }

    private func fenceGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard size.width > 0, size.height > 0 else { return }
                if !dragStarted {
                    dragStarted = true
                    let start = CGPoint(x: v.startLocation.x / size.width, y: v.startLocation.y / size.height)
                    dragIndex = field.nearestFenceIndex(cam: start, maxDistance: 26 / size.width)
                }
                if let i = dragIndex {
                    field.moveFencePoint(i, cam: CGPoint(x: v.location.x / size.width, y: v.location.y / size.height))
                }
            }
            .onEnded { v in
                if dragIndex == nil, hypot(v.translation.width, v.translation.height) < 10, size.width > 0 {
                    field.addFencePoint(cam: CGPoint(x: v.location.x / size.width, y: v.location.y / size.height))
                }
                dragIndex = nil
                dragStarted = false
            }
    }
}

// MARK: - 1 · Laser limits

struct LimitsCard: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    private var busy: Bool { engine.running || engine.preparing || field.calibrating }

    var body: some View {
        Card(title: "1 · Limity laseru") {
            Text("Tečkou na ploše objeď okraj podlahy, kam smí laser svítit (ne stěny ani strop), a v každém rohu klepni na „Přidat roh“. Mimo tuto oblast laser nikdy nepošleme – ani při kalibraci.")
                .font(.footnote).foregroundStyle(.secondary)
            if !laser.isReady {
                HStack {
                    Text("Laser: \(laser.state.rawValue)").foregroundStyle(.secondary)
                    Spacer()
                    if laser.state == .idle || laser.state == .failed {
                        Button("Připojit laser") { laser.connect() }.buttonStyle(.bordered)
                    }
                }
            }
            Toggle("Laser zapnutý", isOn: Binding(get: { laser.laserOn }, set: { laser.setLaser($0) }))
                .disabled(!laser.isReady || busy)
            LaserPad(polygon: field.limits)
                .disabled(busy)
            HStack {
                Text("X \(laser.targetX)  Y \(laser.targetY)").font(.system(.footnote, design: .monospaced))
                Spacer()
                Button {
                    field.addLimitPoint(CGPoint(x: laser.targetX, y: laser.targetY))
                } label: {
                    Label("Přidat roh", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!laser.isReady || busy)
            }
            HStack {
                Button("Zpět") { field.removeLastLimitPoint() }
                    .disabled(field.limits.isEmpty || busy)
                Button("Smazat", role: .destructive) { field.clearLimits() }
                    .disabled(field.limits.isEmpty || busy)
                Spacer()
                Text(field.hasLimits ? "\(field.limits.count) rohů ✓" : "zatím \(field.limits.count) (min. 3)")
                    .font(.footnote).foregroundStyle(field.hasLimits ? Color.green : Color.orange)
            }
            .buttonStyle(.bordered)
        }
    }
}

// MARK: - 2 · Play area

struct FenceCard: View {
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    var body: some View {
        Card(title: "2 · Hřiště") {
            if field.editingFence {
                Text("Klepnutím do obrazu kamery přidáš roh, tažením rohu ho posuneš. Tečka nikdy nevyjede ze žluté oblasti. Laser by měl ve žluté oblasti dosáhnout všude.")
                    .font(.footnote)
                HStack {
                    Button("Zpět") { field.removeLastFencePoint() }
                        .disabled(field.fenceCam.isEmpty)
                    Button("Smazat vše", role: .destructive) { field.clearFence() }
                        .disabled(field.fenceCam.isEmpty)
                    Spacer()
                    Button("Hotovo") { field.editingFence = false }
                        .buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered)
                if field.fenceCam.count > 0 && field.fenceCam.count < 3 {
                    Text("Potřebuješ aspoň 3 rohy.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(field.fenceCam.count >= 3
                     ? "Hřiště: \(field.fenceCam.count) rohů (žlutě). Kalibrace hledá tečku jen v jeho okolí, takže je odolnější vůči odleskům."
                     : "Bez hřiště – tečka smí po celé ploše v limitech laseru, kterou kamera vidí.")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    field.editingFence = true
                } label: {
                    Label(field.fenceCam.isEmpty ? "Nakreslit hřiště" : "Upravit hřiště", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(engine.running || engine.preparing)
            }
            Text("Hřiště se kreslí do obrazu kamery, takže platí jen pro tuto polohu telefonu a tento objektiv.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 3 · Game settings

struct GameSettingsCard: View {
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var engine: PreyEngine

    var body: some View {
        Card(title: "3 · Nastavení hry") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Cíl", selection: $camera.target) {
                    ForEach(DetectTarget.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.segmented)
                .disabled(engine.running || engine.preparing)
                Text(camera.target == .cat
                     ? "Tečka utíká před kočkou."
                     : "Testovací režim: tečka utíká před tvýma nohama – hru vyzkoušíš i bez kočky.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: camera.target) { _ in camera.refreshDetectionSettings() }

            SliderRow(title: "Intenzita", value: $engine.intensity, range: 0...1,
                      label: engine.intensity < 0.35 ? "klidná" : engine.intensity < 0.7 ? "střední" : "divoká")
            SliderRow(title: "Délka hry", value: $engine.sessionMinutes, range: 1...15, step: 1,
                      label: "\(Int(engine.sessionMinutes)) min")
            SliderRow(title: "Nechá se chytit", value: $engine.catchEvery, range: 2...10, step: 1,
                      label: "po ~\(Int(engine.catchEvery)) útěcích")

            Divider()

            Toggle(isOn: $engine.avoidCat) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nesvítit na cíl")
                    Text("Tečka se drží kousek před kočkou, i když ji chytí.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $engine.autoOffWhenLost) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vypnout laser, když cíl zmizí")
                    Text("Vypnuto = tečka pomalu bloudí po hřišti a láká kočku zpátky. Po opětovném zapnutí laser asi 5 s dělá úvodní kolečko.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - 4 · Start

struct StartCard: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    private var timeText: String {
        let s = Int(engine.remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var canStart: Bool {
        laser.isReady && !field.calibrating && (engine.calibrateBeforeGame || field.isCalibrated)
    }

    var body: some View {
        Card(title: "4 · Start") {
            if engine.preparing {
                if engine.countdown > 0 {
                    Text("Start za \(engine.countdown) s – odstup od telefonu a nesahej na něj.")
                        .font(.subheadline.weight(.semibold))
                } else if field.calibrating {
                    ProgressView(value: field.calibrationProgress)
                    Text(field.calibrationStatus).font(.footnote)
                }
            }

            if engine.running {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(engine.mode.rawValue).font(.title3.weight(.semibold))
                        Text("Útěky \(engine.escapes) · chycení \(engine.catches)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(timeText).font(.system(.title2, design: .monospaced).weight(.semibold))
                }
            }

            Button {
                if engine.running || engine.preparing {
                    engine.stop()
                } else {
                    Task { await engine.startFlow() }
                }
            } label: {
                Label(engine.running || engine.preparing ? "Zastavit" : "Spustit hru",
                      systemImage: engine.running || engine.preparing ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.running || engine.preparing ? .red : .accentColor)
            .disabled(!(engine.running || engine.preparing) && !canStart)

            Toggle("Před každou hrou kalibrovat", isOn: $engine.calibrateBeforeGame)
                .disabled(engine.running || engine.preparing)
            Text(engine.calibrateBeforeGame
                 ? "Po stisku: odpočet \(Int(engine.countdownSeconds)) s → kalibrace (~\(estimate) s) → hra hned začne."
                 : (field.isCalibrated ? "Použije se poslední kalibrace – telefon se od ní nesmí pohnout."
                                       : "Chybí kalibrace – zapni kalibraci před hrou."))
                .font(.caption).foregroundStyle(.secondary)

            if !field.hasLimits {
                Text("Doporučení: nejdřív nastav limity laseru (krok 1), jinak kalibrace projede celý rozsah včetně stěn a stropu.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !laser.isReady {
                Text("Laser není připojený.").font(.caption).foregroundStyle(.orange)
            }
            if !engine.message.isEmpty {
                Text(engine.message).font(.footnote)
            }
        }
    }

    private var estimate: Int {
        let n = Double(field.calibrationTargets().count)
        return Int((n * (engine.settleSeconds + 0.15) + 2 + (laser.laserOn ? 0 : engine.warmupSeconds)).rounded())
    }
}

// MARK: - Advanced

struct AdvancedCard: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    private var availableLenses: [CameraLens] { CameraLens.allCases.filter { $0.isAvailable } }
    private var busy: Bool { engine.running || engine.preparing || field.calibrating }

    var body: some View {
        Card(title: "Kamera a kalibrace") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Objektiv", selection: Binding(get: { camera.lens }, set: { camera.setLens($0) })) {
                    ForEach(availableLenses) { l in Text(l.title).tag(l) }
                }
                .pickerStyle(.segmented)
                .disabled(busy)
                Text("Každý objektiv má vlastní kalibraci i hřiště. „1× + LiDAR“ hledá cíl podle hloubky (cokoli, co stojí na podlaze) – funguje i potmě a ze shora.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let c = field.calibration {
                Text(String(format: "Kalibrace: %d bodů, přesnost ±%.1f · %@",
                            c.points, c.rmsError, c.date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Tento objektiv zatím není zkalibrovaný.").font(.footnote).foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 10) {
                SliderRow(title: "Odpočet před startem", value: $engine.countdownSeconds, range: 3...20, step: 1,
                          label: "\(Int(engine.countdownSeconds)) s")
                SliderRow(title: "Čekání na každý bod", value: $engine.settleSeconds, range: 0.5...4, step: 0.25,
                          label: String(format: "%.2f s", engine.settleSeconds))
                SliderRow(title: "Úvodní kolečko laseru", value: $engine.warmupSeconds, range: 2...10, step: 0.5,
                          label: String(format: "%.1f s", engine.warmupSeconds))
                SliderRow(title: "Expozice při kalibraci", value: $engine.exposureBias, range: -3...0, step: 0.25,
                          label: String(format: "%.2f EV", engine.exposureBias))
                Text("Ve světlé místnosti sniž expozici (víc do mínusu) – okolí ztmavne a slabá tečka vynikne.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button {
                Task {
                    _ = await field.calibrate(laser: laser, camera: camera, settle: engine.settleSeconds,
                                              warmup: engine.warmupSeconds, exposureBias: Float(engine.exposureBias))
                }
            } label: {
                Label("Kalibrovat teď (bez hry)", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!laser.isReady || busy || !camera.isRunning)

            if field.calibrating && !engine.preparing {
                Button("Zrušit kalibraci", role: .destructive) { field.cancelRequested = true }
            }
            if !engine.preparing && !field.calibrationStatus.isEmpty {
                Text(field.calibrationStatus).font(.footnote)
            }

            if camera.lens == .lidar {
                LidarSection()
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    SliderRow(title: "Citlivost detekce", value: Binding(
                        get: { Double(camera.minConfidence) },
                        set: { camera.minConfidence = Float($0); camera.refreshDetectionSettings() }
                    ), range: 0.1...0.7, label: String(format: "min. %.0f %%", Double(camera.minConfidence) * 100))
                    Text("Když aplikace cíl nepoznává (např. kočku ze shora), sniž minimum. Když hlásí cíl i tam, kde není, zvyš ho.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct LidarSection: View {
    @EnvironmentObject var camera: CameraManager
    @State private var learning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(camera.depthBackgroundReady
                 ? "LiDAR: prázdná podlaha naučená ✓"
                 : "LiDAR: podlaha zatím není naučená (naučí se sama během kalibrace).")
                .font(.footnote).foregroundStyle(camera.depthBackgroundReady ? Color.green : Color.orange)
            Button {
                learning = true
                camera.beginDepthLearning()
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    camera.finishDepthLearning()
                    learning = false
                }
            } label: {
                Label(learning ? "Učím se…" : "Naučit prázdnou podlahu (4 s)", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(learning)
            SliderRow(title: "Min. výška objektu", value: Binding(
                get: { Double(camera.depthThreshold) * 100 },
                set: { camera.depthThreshold = Float($0 / 100); camera.refreshDetectionSettings() }
            ), range: 2...15, step: 1, label: String(format: "%.0f cm", Double(camera.depthThreshold) * 100))
            Text("Při učení nesmí být kočka ani nikdo jiný v záběru.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared slider row

struct SliderRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    var step: Double? = nil
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label).font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let s = step {
                Slider(value: value, in: range, step: s)
            } else {
                Slider(value: value, in: range)
            }
        }
    }
}

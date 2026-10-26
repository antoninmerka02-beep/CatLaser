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
                    GameCard()
                    CalibrationCard()
                    FenceCard()
                    GameSettingsCard()
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
            if !engine.running && !field.calibrating { camera.stop() }
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
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.0f fps · detekce %.0f/s · kočka %.0f %%",
                        camera.fps, camera.detectFps, Double(camera.lastDetectionConfidence) * 100))
                .font(.system(size: 10, design: .monospaced))
                .padding(4)
                .background(Color.black.opacity(0.5))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .padding(6)
        }
        .frame(height: 460)
        .frame(maxWidth: .infinity)
    }

    private func overlay(size: CGSize) -> some View {
        let w = size.width, h = size.height
        let toView: (CGPoint) -> CGPoint = { CGPoint(x: $0.x * w, y: $0.y * h) }
        let reach = (field.calibration?.reach ?? []).compactMap { field.laserToCamPoint($0) }.map(toView)
        let fence = field.fence.compactMap { field.laserToCamPoint($0) }.map(toView)
        let editing = field.editingFence
        let now = CACurrentMediaTime()
        let cat = field.cat.flatMap { now - $0.time < 1.0 ? $0 : nil }
        let catRect = cat.map { CGRect(x: $0.rect.minX * w, y: $0.rect.minY * h, width: $0.rect.width * w, height: $0.rect.height * h) }
        let catConf = cat?.confidence ?? 0
        let dotLaser = engine.running ? engine.dot : CGPoint(x: laser.targetX, y: laser.targetY)
        let dot = field.isCalibrated ? field.laserToCamPoint(dotLaser).map(toView) : nil
        let calibDot = field.calibrating ? field.lastDotCam.map(toView) : nil

        return Canvas { ctx, _ in
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
            if let r = catRect {
                ctx.stroke(Path(roundedRect: r, cornerRadius: 6), with: .color(.green), lineWidth: 2)
                ctx.draw(Text(String(format: "kočka %.0f %%", Double(catConf) * 100))
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(.green),
                         at: CGPoint(x: r.minX + 4, y: max(8, r.minY - 9)), anchor: .leading)
            }
            if let d = dot {
                let r = CGRect(x: d.x - 8, y: d.y - 8, width: 16, height: 16)
                ctx.stroke(Path(ellipseIn: r), with: .color(.red), lineWidth: 2.5)
                ctx.fill(Path(ellipseIn: r.insetBy(dx: 5, dy: 5)), with: .color(.red))
            }
            if let c = calibDot {
                let r = CGRect(x: c.x - 12, y: c.y - 12, width: 24, height: 24)
                ctx.stroke(Path(ellipseIn: r), with: .color(.white), lineWidth: 2)
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

// MARK: - Game

struct GameCard: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    private var timeText: String {
        let s = Int(engine.remaining.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        Card(title: "Hra") {
            if !laser.isReady {
                HStack {
                    Text("Laser: \(laser.state.rawValue)").foregroundStyle(.secondary)
                    Spacer()
                    if laser.state == .idle || laser.state == .failed {
                        Button("Připojit laser") { laser.connect() }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if !field.isCalibrated {
                Text("Pro tento objektiv zatím chybí kalibrace.")
                    .font(.footnote).foregroundStyle(.orange)
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
                if engine.running { engine.stop() } else { engine.start() }
            } label: {
                Label(engine.running ? "Zastavit hru" : "Spustit hru",
                      systemImage: engine.running ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.running ? .red : .accentColor)
            .disabled(!engine.running && (!laser.isReady || !field.isCalibrated || field.calibrating))

            if !engine.message.isEmpty {
                Text(engine.message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Calibration

struct CalibrationCard: View {
    @EnvironmentObject var laser: LaserController
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    private var availableLenses: [CameraLens] { CameraLens.allCases.filter { $0.isAvailable } }

    var body: some View {
        Card(title: "Kamera a kalibrace") {
            if availableLenses.count > 1 {
                Picker("Objektiv", selection: Binding(
                    get: { camera.lens },
                    set: { camera.setLens($0) }
                )) {
                    ForEach(availableLenses) { l in Text(l.title).tag(l) }
                }
                .pickerStyle(.segmented)
                .disabled(engine.running || field.calibrating)
            } else {
                Text("Objektiv: \(camera.lens.title)").font(.footnote).foregroundStyle(.secondary)
            }

            if let c = field.calibration {
                Text(String(format: "Kalibrováno: %d bodů, přesnost ±%.1f · %@",
                            c.points, c.rmsError,
                            c.date.formatted(date: .abbreviated, time: .shortened)))
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Tento objektiv ještě není zkalibrovaný.")
                    .font(.footnote).foregroundStyle(.orange)
            }

            if field.calibrating {
                ProgressView(value: field.calibrationProgress)
            }
            if !field.calibrationStatus.isEmpty {
                Text(field.calibrationStatus).font(.footnote)
            }

            Button {
                Task { await field.calibrate(laser: laser, camera: camera) }
            } label: {
                Label(field.isCalibrated ? "Kalibrovat znovu" : "Kalibrovat", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!laser.isReady || field.calibrating || engine.running || !camera.isRunning)

            Text("Telefon musí stát pevně a vidět plochu, kam laser svítí. Během kalibrace (asi 20 s) laser projede 16 bodů – kočka by neměla být v záběru. Po posunutí telefonu nebo laseru kalibruj znovu. Každý objektiv má vlastní kalibraci.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Fence

struct FenceCard: View {
    @EnvironmentObject var field: FieldModel
    @EnvironmentObject var engine: PreyEngine

    var body: some View {
        Card(title: "Ohraničení hřiště") {
            if field.editingFence {
                Text("Klepnutím do obrazu přidáš roh, tažením rohu ho posuneš. Tečka nikdy nevyjede ven ze žluté oblasti.")
                    .font(.footnote)
                HStack {
                    Button("Zpět") { field.removeLastFencePoint() }
                        .disabled(field.fence.isEmpty)
                    Button("Smazat vše", role: .destructive) { field.clearFence() }
                        .disabled(field.fence.isEmpty)
                    Spacer()
                    Button("Hotovo") { field.editingFence = false }
                        .buttonStyle(.borderedProminent)
                }
                .buttonStyle(.bordered)
                if field.fence.count > 0 && field.fence.count < 3 {
                    Text("Potřebuješ aspoň 3 rohy.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text(field.fence.count >= 3
                     ? "Aktivní ohraničení: \(field.fence.count) rohů (žlutě). Modrá čárkovaná = kam laser dosáhne."
                     : "Bez ohraničení – tečka se pohybuje po celé dosažitelné ploše (modrá čárkovaná).")
                    .font(.footnote).foregroundStyle(.secondary)
                Button {
                    field.editingFence = true
                } label: {
                    Label(field.fence.isEmpty ? "Nakreslit ohraničení" : "Upravit ohraničení", systemImage: "pencil.and.outline")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!field.isCalibrated || engine.running)
            }
        }
    }
}

// MARK: - Settings

struct GameSettingsCard: View {
    @EnvironmentObject var camera: CameraManager
    @EnvironmentObject var engine: PreyEngine

    var body: some View {
        Card(title: "Nastavení hry") {
            sliderRow("Intenzita", value: $engine.intensity, range: 0...1,
                      label: engine.intensity < 0.35 ? "klidná" : engine.intensity < 0.7 ? "střední" : "divoká")
            sliderRow("Délka hry", value: $engine.sessionMinutes, range: 1...15, step: 1,
                      label: "\(Int(engine.sessionMinutes)) min")
            sliderRow("Nechá se chytit", value: $engine.catchEvery, range: 2...10, step: 1,
                      label: "po ~\(Int(engine.catchEvery)) útěcích")

            Divider()

            Toggle(isOn: $engine.avoidCat) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nesvítit na kočku")
                    Text("Tečka se drží mimo kočku; při chycení zhasne místo svícení na tlapku.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: $engine.autoOffWhenLost) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vypnout laser, když kočka zmizí")
                    Text("Vypnuto = tečka pomalu bloudí po hřišti a láká kočku zpátky.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            sliderRow("Citlivost detekce", value: Binding(
                get: { Double(camera.minConfidence) },
                set: { camera.minConfidence = Float($0) }
            ), range: 0.1...0.7, label: String(format: "min. %.0f %%", Double(camera.minConfidence) * 100))
            Text("Když aplikace kočku nepoznává (např. ze shora), sniž minimum. Když hlásí kočku i tam, kde není, zvyš ho.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double? = nil, label: String) -> some View {
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

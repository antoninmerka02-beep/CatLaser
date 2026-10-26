import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var laser: LaserController
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard(showSettings: $showSettings)
                    ControlsCard()
                    PadCard()
                    LatencyCard()
                    LogCard()
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("CatLaser test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                if Credentials.load() == nil { showSettings = true }
            }
        }
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct StatusCard: View {
    @EnvironmentObject var laser: LaserController
    @Binding var showSettings: Bool

    private var color: Color {
        switch laser.state {
        case .ready: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }

    var body: some View {
        Card(title: "Spojení") {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(laser.state.rawValue).font(.body.weight(.semibold))
                Spacer()
                if laser.state == .idle || laser.state == .failed {
                    Button("Připojit") { laser.connect() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Odpojit", role: .destructive) { laser.disconnect() }
                        .buttonStyle(.bordered)
                }
            }
            if !laser.statusDetail.isEmpty {
                Text(laser.statusDetail).font(.footnote).foregroundStyle(.red)
            }
            if !laser.deviceInfo.isEmpty {
                Text(laser.deviceInfo).font(.footnote).foregroundStyle(.secondary)
            }
            Text("Před připojením zavři Smart Life / Tesla aplikaci – laser zvládne jen jedno spojení.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ControlsCard: View {
    @EnvironmentObject var laser: LaserController

    var body: some View {
        Card(title: "Laser") {
            Toggle("Laser zapnutý", isOn: Binding(
                get: { laser.laserOn },
                set: { laser.setLaser($0) }
            ))
            .disabled(!laser.isReady)

            VStack(alignment: .leading, spacing: 6) {
                Text("Vestavěný režim").font(.subheadline).foregroundStyle(.secondary)
                Picker("Režim", selection: Binding(
                    get: { laser.preset },
                    set: { laser.setPreset($0) }
                )) {
                    Text("Stop").tag(0)
                    Text("Malý").tag(1)
                    Text("Střední").tag(2)
                    Text("Velký").tag(3)
                }
                .pickerStyle(.segmented)
                .disabled(!laser.isReady)
            }

            HStack {
                Button("Synchronizovat čas") { laser.syncTime() }
                Spacer()
                Button("Načíst stav") { laser.requestStatus() }
            }
            .buttonStyle(.bordered)
            .disabled(!laser.isReady)
        }
    }
}

struct PadCard: View {
    @EnvironmentObject var laser: LaserController

    var body: some View {
        Card(title: "Ruční ovládání") {
            Text("Táhni prstem po ploše – tečka by měla sledovat prst. Rozsah 0–400, střed 200/200.")
                .font(.footnote).foregroundStyle(.secondary)
            LaserPad()
            HStack {
                Text("X \(laser.targetX)  Y \(laser.targetY)")
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button("Na střed") { laser.centre() }
                    .buttonStyle(.bordered)
                    .disabled(!laser.isReady)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Testovací pohyb").font(.subheadline).foregroundStyle(.secondary)
                Picker("Vzor", selection: $laser.pattern) {
                    ForEach(LaserController.TestPattern.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!laser.isReady)
                HStack {
                    Text("Rychlost")
                    Slider(value: $laser.patternSpeed, in: 0.1...2.0)
                    Text(String(format: "%.1f/s", laser.patternSpeed))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(width: 52, alignment: .trailing)
                }
                Text("„Skoky“ přeskakují mezi dvěma body – natoč to zpomaleně a uvidíš skutečné zpoždění.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct LaserPad: View {
    @EnvironmentObject var laser: LaserController

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(uiColor: .tertiarySystemGroupedBackground))
                Path { p in
                    p.move(to: CGPoint(x: side / 2, y: 0))
                    p.addLine(to: CGPoint(x: side / 2, y: side))
                    p.move(to: CGPoint(x: 0, y: side / 2))
                    p.addLine(to: CGPoint(x: side, y: side / 2))
                }
                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.red)
                    .frame(width: 20, height: 20)
                    .shadow(color: .red.opacity(0.6), radius: 6)
                    .position(x: CGFloat(laser.targetX) / 400 * side,
                              y: CGFloat(laser.targetY) / 400 * side)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let x = Int((v.location.x / side * 400).rounded())
                        let y = Int((v.location.y / side * 400).rounded())
                        laser.userMove(x: x, y: y)
                    }
            )
            .opacity(laser.isReady ? 1 : 0.5)
            .allowsHitTesting(laser.isReady)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

struct LatencyCard: View {
    @EnvironmentObject var laser: LaserController

    private func ms(_ v: Double?) -> String {
        guard let v = v else { return "–" }
        return "\(Int(v.rounded())) ms"
    }

    var body: some View {
        Card(title: "Odezva (potvrzení od laseru)") {
            HStack {
                stat("Poslední", ms(laser.lastRtt))
                stat("Průměr", ms(laser.avgRtt))
                stat("Max", ms(laser.maxRtt))
            }
            HStack {
                stat("Odesláno", "\(laser.movesSent)")
                stat("Potvrzeno", "\(laser.movesAcked)")
                stat("Ztraceno", "\(laser.movesLost)")
            }
            Toggle("Další pohyb až po potvrzení", isOn: $laser.waitForAck)
            HStack {
                Text("Min. interval")
                Slider(value: $laser.minIntervalMs, in: 0...200, step: 5)
                Text("\(Int(laser.minIntervalMs)) ms")
                    .font(.system(.footnote, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            Button("Vynulovat statistiku") { laser.resetStats() }
                .buttonStyle(.bordered)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced).weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LogCard: View {
    @EnvironmentObject var laser: LaserController
    @State private var copied = false

    var body: some View {
        Card(title: "Log") {
            Toggle("Podrobný log (každý paket)", isOn: $laser.verboseLog)
            HStack {
                Button(copied ? "Zkopírováno ✓" : "Kopírovat log") {
                    UIPasteboard.general.string = laser.log.joined(separator: "\n")
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                Spacer()
                Button("Vymazat", role: .destructive) { laser.clearLog() }
            }
            .buttonStyle(.bordered)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(laser.log.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 280)
                .background(Color(uiColor: .tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: laser.log.count) { count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Credentials.deviceIdKey) private var deviceId = ""
    @AppStorage(Credentials.localKeyKey) private var localKey = ""
    @AppStorage(Credentials.uuidKey) private var uuid = ""
    @State private var message = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        pasteJSON()
                    } label: {
                        Label("Vložit JSON ze schránky", systemImage: "doc.on.clipboard")
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote)
                    }
                } footer: {
                    Text("Zkopíruj celou odpověď z Tuya API Exploreru (Query Device Details) a klepni sem – údaje se vyplní samy.")
                }

                Section("Údaje zařízení") {
                    field("Device ID", $deviceId)
                    field("Local key", $localKey)
                    field("UUID", $uuid)
                }

                Section {
                    Text("Údaje se ukládají jen v tomto telefonu. Local key se mění, pokud laser v aplikaci odebereš a znovu spáruješ.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hotovo") { dismiss() }
                }
            }
        }
    }

    private func field(_ title: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: binding)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func pasteJSON() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            message = "Schránka je prázdná."
            return
        }
        guard let c = Credentials.parse(json: text) else {
            message = "V JSONu jsem nenašel id, local_key a uuid."
            return
        }
        deviceId = c.deviceId
        localKey = c.localKey
        uuid = c.uuid
        message = "✓ Načteno zařízení \(c.deviceId)"
    }
}

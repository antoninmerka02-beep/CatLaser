import SwiftUI

final class AppModel: ObservableObject {
    let laser = LaserController()
    let camera = CameraManager()
    let field: FieldModel
    let engine: PreyEngine

    init() {
        field = FieldModel(camera: camera)
        engine = PreyEngine(laser: laser, field: field)
    }
}

@main
struct CatLaserApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app.laser)
                .environmentObject(app.camera)
                .environmentObject(app.field)
                .environmentObject(app.engine)
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("Hra", systemImage: "pawprint.fill") }
            ContentView()
                .tabItem { Label("Test", systemImage: "slider.horizontal.3") }
        }
    }
}

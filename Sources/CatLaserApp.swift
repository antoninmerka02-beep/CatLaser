import SwiftUI

@main
struct CatLaserApp: App {
    @StateObject private var laser = LaserController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(laser)
        }
    }
}

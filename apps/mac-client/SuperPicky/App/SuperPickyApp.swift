import SwiftUI

@main
struct SuperPickyApp: App {
    var body: some Scene {
        WindowGroup {
            Text("SuperPicky")
                .frame(width: 800, height: 600)
        }
        .windowStyle(.titleBar)

        Settings {
            Text("Settings")
        }
    }
}

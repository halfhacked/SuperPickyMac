import SwiftUI

@main
struct SuperPickyApp: App {
    @State private var processManager = ProcessManager()
    @State private var config = CullingConfig()

    var body: some Scene {
        WindowGroup {
            ThreeColumnView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(processManager)
                .environment(config)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            Text("Settings — coming soon")
        }
    }
}

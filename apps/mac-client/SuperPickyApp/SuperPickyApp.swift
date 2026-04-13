import SwiftUI

@main
struct SuperPickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var processManager = ProcessManager()
    @State private var config = CullingConfig()

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(processManager)
                .environment(config)
                .preferredColorScheme(config.appTheme.colorScheme)
                .onAppear {
                    appDelegate.processManager = processManager
                    processManager.start()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environment(config)
        }
    }
}

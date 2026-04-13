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
                .onChange(of: config.appTheme) { _, theme in
                    // Apply immediately to all windows including Settings
                    switch theme {
                    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                    case .light: NSApp.appearance = NSAppearance(named: .aqua)
                    case .system: NSApp.appearance = nil
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environment(config)
                .preferredColorScheme(config.appTheme.colorScheme)
        }
    }
}

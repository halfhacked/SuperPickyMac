import SwiftUI

@main
struct SuperPickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var processManager = ProcessManager()
    @State private var config = CullingConfig()
    @State private var serverSetup = ServerSetup()

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainView()
                    .frame(minWidth: 900, minHeight: 600)
                    .environment(processManager)
                    .environment(config)
                    .environment(\.locale, config.appLanguage.locale)
                    .preferredColorScheme(config.appTheme.colorScheme)

                if serverSetup.isSettingUp {
                    SetupOverlay(progress: serverSetup.setupProgress)
                }
            }
            .onAppear {
                appDelegate.processManager = processManager
                LocalizationManager.localizeMenuBar(language: config.appLanguage)

                Task {
                    let ready = await serverSetup.ensureSetup()
                    if ready {
                        processManager.start()
                    }
                }
            }
            .onChange(of: config.appTheme) { _, theme in
                switch theme {
                case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                case .light: NSApp.appearance = NSAppearance(named: .aqua)
                case .system: NSApp.appearance = nil
                }
            }
            .alert(config.localized("Setup Failed"), isPresented: $serverSetup.setupFailed) {
                Button(config.localized("Retry")) {
                    Task {
                        let ready = await serverSetup.ensureSetup()
                        if ready { processManager.start() }
                    }
                }
                Button(config.localized("Quit"), role: .destructive) { NSApp.terminate(nil) }
            } message: {
                Text(serverSetup.setupError)
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

/// Overlay shown during first-launch Python environment setup
struct SetupOverlay: View {
    @Environment(CullingConfig.self) private var config
    let progress: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(config.localized("Setting up SuperPicky"))
                    .font(.title2.bold())
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

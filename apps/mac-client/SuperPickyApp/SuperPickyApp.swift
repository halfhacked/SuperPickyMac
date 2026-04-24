import SwiftUI
import SuperPickyInference

@main
struct SuperPickyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var config: CullingConfig
    @State private var modelState: ModelDownloadState

    init() {
        // Under TEST_MODE, wipe the entire persistent prefs domain
        // before CullingConfig reads it and before SwiftUI restores
        // any NSWindow Frame / NSSplitView Subview Frames state.
        // Dev-time prefs (appLanguage=zh-Hans, appTheme=dark) and
        // prior-class window geometry would otherwise leak into the
        // test and flake sidebar / toolbar assertions.
        // See docs/ci-perf-retry-notes.md.
        if ProcessInfo.processInfo.environment["TEST_MODE"] == "1",
           let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        _config = State(wrappedValue: CullingConfig())
        _modelState = State(wrappedValue: ModelDownloadState())
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                MainView(modelState: modelState)
                    .frame(minWidth: 900, minHeight: 600)

                if modelState.isDownloading || modelState.errorMessage != nil {
                    ModelDownloadOverlay(state: modelState)
                }
            }
            .environment(config)
            .environment(\.locale, config.appLanguage.locale)
            .preferredColorScheme(config.appTheme.colorScheme)
            .onAppear {
                LocalizationManager.localizeMenuBar(language: config.appLanguage)
                Task { await modelState.ensureReady() }
            }
            .onChange(of: config.appTheme) { _, theme in
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

        Window("World Clock", id: "timezone-picker") {
            TimezonePickerView()
                .frame(minWidth: 520, minHeight: 720)
        }
        .defaultSize(width: 520, height: 720)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .windowList) {
                OpenWorldClockCommand()
            }
        }
    }
}

private struct OpenWorldClockCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("World Clock") {
            openWindow(id: "timezone-picker")
        }
        .keyboardShortcut("0", modifiers: [.command, .shift])
    }
}

// MARK: - Model download state

/// @Observable wrapper around ModelManager, driven by the app.
@Observable
final class ModelDownloadState {

    static let cacheDir: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("com.superpicky.mac/ModelCache")
    }()

    var isDownloading = true   // true until manager reaches .ready or .failed
    var progress: Double = 0
    var currentFile: String = ""
    var errorMessage: String? = nil
    var modelsDir: URL { Self.cacheDir }

    private let manager: ModelManager

    init() {
        let manifest = (try? ModelManifest.loadBundled()) ?? ModelManifest(version: 1, models: [])
        self.manager = ModelManager(manifest: manifest, rootDir: Self.cacheDir)
    }

    func ensureReady() async {
        // Subscribe to state changes BEFORE kicking off the download so we
        // don't miss any transitions. `observe()` yields the current state
        // immediately as its first element.
        let stream = await manager.observe()

        // Drive the download in a separate task; this method consumes the
        // observer stream until it terminates (on .ready or .failed).
        Task.detached { [manager] in
            do { try await manager.ensureReady() } catch { /* observer picks up .failed */ }
        }

        for await s in stream {
            await MainActor.run {
                switch s {
                case .notStarted:
                    isDownloading = true
                case .copyingScaffolds:
                    isDownloading = true
                    currentFile = "Preparing…"
                case .downloading(let p, let file):
                    isDownloading = true
                    progress = p
                    currentFile = file
                case .verifying(let file):
                    isDownloading = true
                    currentFile = "Verifying \(file)…"
                case .ready:
                    isDownloading = false
                    errorMessage = nil
                case .failed(let err):
                    isDownloading = false
                    errorMessage = err.localizedDescription
                }
            }
        }
    }

    func retry() {
        Task {
            isDownloading = true
            errorMessage = nil
            await ensureReady()
        }
    }
}

// MARK: - Download progress overlay

struct ModelDownloadOverlay: View {
    @Environment(CullingConfig.self) private var config
    let state: ModelDownloadState

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            VStack(spacing: 16) {
                if let error = state.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(config.localized("Download Failed"))
                        .font(.title2.bold())
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                        Button(config.localized("Retry")) { state.retry() }
                            .buttonStyle(.borderedProminent)
                        Button(config.localized("Quit"), role: .destructive) { NSApp.terminate(nil) }
                    }
                } else {
                    ProgressView()
                        .controlSize(.large)
                    Text(config.localized("Downloading models…"))
                        .font(.title2.bold())
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 280)
                    Text(state.currentFile)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(40)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .ignoresSafeArea()
    }
}

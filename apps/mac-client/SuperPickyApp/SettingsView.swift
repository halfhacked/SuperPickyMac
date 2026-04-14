import SwiftUI

struct SettingsView: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(config.localized("General"), systemImage: "gear") }
            CullingTab()
                .tabItem { Label(config.localized("Culling"), systemImage: "slider.horizontal.3") }
            BirdIDTab()
                .tabItem { Label(config.localized("Bird ID"), systemImage: "bird") }
            ProcessingTab()
                .tabItem { Label(config.localized("Processing"), systemImage: "arrow.triangle.2.circlepath") }
            AdvancedTab()
                .tabItem { Label(config.localized("Advanced"), systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 500, height: 300)
        .environment(\.locale, config.appLanguage.locale)
        .task(id: config.appLanguage) {
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                LocalizationManager.localizeMenuBar(language: config.appLanguage)
            }
        }
    }
}

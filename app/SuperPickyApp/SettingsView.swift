import SwiftUI

struct SettingsView: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label(config.localized("General"), systemImage: "gear") }
                .accessibilityIdentifier("SettingsTab_General")
            CullingTab()
                .tabItem { Label(config.localized("Culling"), systemImage: "slider.horizontal.3") }
                .accessibilityIdentifier("SettingsTab_Culling")
            BirdIDTab()
                .tabItem { Label(config.localized("Bird ID"), systemImage: "bird") }
                .accessibilityIdentifier("SettingsTab_BirdID")
            AdvancedTab()
                .tabItem { Label(config.localized("Advanced"), systemImage: "wrench.and.screwdriver") }
                .accessibilityIdentifier("SettingsTab_Advanced")
        }
        .frame(width: 640, height: 360)
        .accessibilityIdentifier("SettingsTabView")
        .environment(\.locale, config.appLanguage.locale)
        .task(id: config.appLanguage) {
            try? await Task.sleep(for: .milliseconds(100))
            await MainActor.run {
                LocalizationManager.localizeMenuBar(language: config.appLanguage)
            }
        }
    }
}

import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gear") }
            CullingTab()
                .tabItem { Label("Culling", systemImage: "slider.horizontal.3") }
            BirdIDTab()
                .tabItem { Label("Bird ID", systemImage: "bird") }
            ProcessingTab()
                .tabItem { Label("Processing", systemImage: "arrow.triangle.2.circlepath") }
            AdvancedTab()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 500, height: 300)
    }
}

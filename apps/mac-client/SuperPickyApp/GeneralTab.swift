import SwiftUI

struct GeneralTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Toggle("Auto-advance after rating", isOn: $config.autoAdvance)

            Picker("Language", selection: $config.appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Picker("Appearance", selection: $config.appTheme) {
                Text("System").tag(AppTheme.system)
                Text("Dark").tag(AppTheme.dark)
                Text("Light").tag(AppTheme.light)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

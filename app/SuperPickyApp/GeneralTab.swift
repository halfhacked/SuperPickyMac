import SwiftUI

struct GeneralTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Toggle(config.localized("Auto-advance after rating"), isOn: $config.autoAdvance)

            Picker(config.localized("Language"), selection: $config.appLanguage) {
                ForEach(AppLanguage.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }

            Picker(config.localized("Appearance"), selection: $config.appTheme) {
                Text(config.localized("System")).tag(AppTheme.system)
                Text(config.localized("Dark")).tag(AppTheme.dark)
                Text(config.localized("Light")).tag(AppTheme.light)
            }
            .pickerStyle(.segmented)
        }
        .formStyle(.grouped)
    }
}

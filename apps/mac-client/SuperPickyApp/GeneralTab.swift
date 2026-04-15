import SwiftUI

struct GeneralTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Picker("Skill Level", selection: $config.skillLevel) {
                ForEach(SkillLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Text("Skill level sets default thresholds for sharpness and aesthetics scoring.")
                .font(.caption)
                .foregroundStyle(.secondary)

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

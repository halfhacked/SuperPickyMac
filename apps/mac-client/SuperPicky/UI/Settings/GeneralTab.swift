import SwiftUI

struct GeneralTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Picker("Skill Level", selection: $config.skillLevel) {
                ForEach(SkillLevel.allCases, id: \.self) { level in
                    Text(level.rawValue.capitalized).tag(level)
                }
            }
            .pickerStyle(.segmented)

            Text("Skill level sets default thresholds for sharpness and aesthetics scoring.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

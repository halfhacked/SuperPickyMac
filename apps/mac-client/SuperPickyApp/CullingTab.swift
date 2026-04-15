import SwiftUI

struct CullingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section {
                Picker(config.localized("Skill Level"), selection: Binding(
                    get: { config.skillLevel },
                    set: { config.applySkillLevel($0) }
                )) {
                    Text(config.localized("Beginner")).tag(SkillLevel.beginner)
                    Text(config.localized("Intermediate")).tag(SkillLevel.intermediate)
                    Text(config.localized("Master")).tag(SkillLevel.master)
                    Text(config.localized("Custom")).tag(SkillLevel.custom)
                }
                Text(config.localized("Skill level sets default thresholds for sharpness and aesthetics scoring."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(config.localized("Detection")) {
                Toggle(config.localized("Enable exposure detection"), isOn: $config.exposureDetectionEnabled)
                if config.exposureDetectionEnabled {
                    HStack {
                        Text(config.localized("Threshold"))
                        Slider(value: $config.exposureThreshold, in: 0.05...0.20, step: 0.01)
                        Text("\(Int(config.exposureThreshold * 100))%")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
                Toggle(config.localized("Enable flight detection"), isOn: $config.flightDetectionEnabled)
            }

            Section(config.localized("Picks")) {
                HStack {
                    Text(config.localized("Top percentage"))
                    Slider(
                        value: Binding(
                            get: { Double(config.pickedTopPercentage) },
                            set: { config.pickedTopPercentage = Int($0) }
                        ),
                        in: 10...50,
                        step: 5
                    )
                    Text("\(config.pickedTopPercentage)%")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Text(config.localized("Percentage of top-rated photos to flag as picks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

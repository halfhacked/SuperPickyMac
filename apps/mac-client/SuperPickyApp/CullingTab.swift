import SwiftUI

struct CullingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section(config.localized("Detection")) {
                Toggle(config.localized("Enable exposure detection"), isOn: $config.exposureDetectionEnabled)
                if config.exposureDetectionEnabled {
                    SliderRow(label: config.localized("Threshold"),
                              value: snappedBinding($config.exposureThreshold, step: 0.01),
                              range: 0.05...0.20,
                              display: "\(Int(config.exposureThreshold * 100))%")
                }
                Toggle(config.localized("Enable flight detection"), isOn: $config.flightDetectionEnabled)
            }

            Section(config.localized("Picks")) {
                SliderRow(label: config.localized("Top percentage"),
                          value: Binding(
                              get: { Double(config.pickedTopPercentage) },
                              set: { config.pickedTopPercentage = (Int(($0 / 5).rounded()) * 5) }
                          ),
                          range: 10...50,
                          display: "\(config.pickedTopPercentage)%")
                Text(config.localized("Percentage of top-rated photos to flag as picks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

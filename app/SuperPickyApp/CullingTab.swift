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
                    Text(config.localized("Fraction of clipped pixels that flags a photo as over- or under-exposed. Lower values flag more photos."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle(config.localized("Enable flight detection"), isOn: $config.flightDetectionEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

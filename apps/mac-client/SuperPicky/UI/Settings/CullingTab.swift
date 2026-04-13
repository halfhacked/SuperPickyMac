import SwiftUI

struct CullingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section("Thresholds") {
                HStack {
                    Text("Sharpness")
                    Slider(value: $config.sharpnessThreshold, in: 100...800, step: 10)
                    Text("\(Int(config.sharpnessThreshold))")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                HStack {
                    Text("Aesthetics")
                    Slider(value: $config.aestheticsThreshold, in: 2.0...8.0, step: 0.1)
                    Text(String(format: "%.1f", config.aestheticsThreshold))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
            Section("Exposure") {
                Toggle("Enable exposure detection", isOn: $config.exposureDetectionEnabled)
                if config.exposureDetectionEnabled {
                    HStack {
                        Text("Threshold")
                        Slider(value: $config.exposureThreshold, in: 0.05...0.20, step: 0.01)
                        Text("\(Int(config.exposureThreshold * 100))%")
                            .monospacedDigit()
                            .frame(width: 40)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

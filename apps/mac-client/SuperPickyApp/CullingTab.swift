import SwiftUI

struct CullingTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
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

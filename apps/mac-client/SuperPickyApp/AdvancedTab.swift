import SwiftUI

struct AdvancedTab: View {
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
                HStack {
                    Text("Eye Sharpness")
                    Slider(value: $config.eyeSharpnessThreshold, in: 0...300, step: 10)
                    Text("\(Int(config.eyeSharpnessThreshold))")
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
            Section("Burst Detection") {
                Toggle("Enable burst detection", isOn: $config.burstDetectionEnabled)
            }
            Section(config.localized("Backend")) {
                HStack {
                    Text(config.localized("Python server port"))
                    TextField("Port", value: $config.backendPort, format: .number)
                        .frame(width: 80)
                }
            }
            Section(config.localized("Inference Backend")) {
                Picker(config.localized("Inference Backend"), selection: $config.inferenceBackend) {
                    Text(config.localized("HTTP (Python server)")).tag(InferenceBackend.http)
                    // Phase 1 adds: Text(config.localized("Native Core ML")).tag(InferenceBackend.native)
                }
                .labelsHidden()
                Text(config.localized("Native Core ML backend will be available in a future release."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

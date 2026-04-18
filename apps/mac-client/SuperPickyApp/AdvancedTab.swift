import SwiftUI

struct AdvancedTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section(config.localized("Thresholds")) {
                HStack {
                    Text(config.localized("Sharpness"))
                    Slider(value: $config.sharpnessThreshold, in: 100...800, step: 10)
                    Text("\(Int(config.sharpnessThreshold))")
                        .monospacedDigit()
                        .frame(width: 40)
                }
                HStack {
                    Text(config.localized("Aesthetics"))
                    Slider(value: $config.aestheticsThreshold, in: 2.0...8.0, step: 0.1)
                    Text(String(format: "%.1f", config.aestheticsThreshold))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                HStack {
                    Text(config.localized("Min Confidence"))
                    Slider(value: $config.minConfidence, in: 0.3...0.7, step: 0.05)
                    Text(String(format: "%.2f", config.minConfidence))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                HStack {
                    Text(config.localized("Min Aesthetics"))
                    Slider(value: $config.minAesthetics, in: 2.0...5.0, step: 0.1)
                    Text(String(format: "%.1f", config.minAesthetics))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }
            Section(config.localized("Burst Detection")) {
                Toggle(config.localized("Enable burst detection"), isOn: $config.burstDetectionEnabled)
                if config.burstDetectionEnabled {
                    HStack {
                        Text(config.localized("Burst FPS"))
                        Slider(
                            value: Binding(
                                get: { Double(config.burstFps) },
                                set: { config.burstFps = Int($0) }
                            ),
                            in: 4...20,
                            step: 1
                        )
                        Text("\(config.burstFps)")
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    HStack {
                        Text(config.localized("Min Burst Count"))
                        Slider(
                            value: Binding(
                                get: { Double(config.burstMinCount) },
                                set: { config.burstMinCount = Int($0) }
                            ),
                            in: 2...10,
                            step: 1
                        )
                        Text("\(config.burstMinCount)")
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                    HStack {
                        Text(config.localized("Hash Tolerance"))
                        Slider(
                            value: Binding(
                                get: { Double(config.burstHashTolerance) },
                                set: { config.burstHashTolerance = Int($0) }
                            ),
                            in: 4...30,
                            step: 1
                        )
                        Text("\(config.burstHashTolerance)")
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

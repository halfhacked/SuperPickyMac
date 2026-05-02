import SwiftUI

struct AdvancedTab: View {
    @Environment(CullingConfig.self) private var config

    var body: some View {
        @Bindable var config = config
        Form {
            Section(config.localized("Thresholds")) {
                SliderRow(label: config.localized("Sharpness"),
                          value: snappedBinding($config.sharpnessThreshold, step: 10),
                          range: 100...800,
                          display: "\(Int(config.sharpnessThreshold))")
                Text(config.localized("Tenengrad sharpness-score floor. Photos below this are rated low."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(label: config.localized("Aesthetics"),
                          value: snappedBinding($config.aestheticsThreshold, step: 0.1),
                          range: 2.0...8.0,
                          display: String(format: "%.1f", config.aestheticsThreshold))
                Text(config.localized("Aesthetics-model score floor. Photos below this are rated low."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(label: config.localized("Min Confidence"),
                          value: snappedBinding($config.minConfidence, step: 0.05),
                          range: 0.3...0.7,
                          display: String(format: "%.2f", config.minConfidence))
                Text(config.localized("Bird-detection confidence floor. Below this, the photo is treated as having no bird."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SliderRow(label: config.localized("Min Aesthetics"),
                          value: snappedBinding($config.minAesthetics, step: 0.1),
                          range: 2.0...5.0,
                          display: String(format: "%.1f", config.minAesthetics))
                Text(config.localized("Hard aesthetics floor — photos below this can never reach the top picks."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(config.localized("Preview Cache")) {
                PreviewCacheSettings()
            }
            Section(config.localized("Burst Detection")) {
                Toggle(config.localized("Enable burst detection"), isOn: $config.burstDetectionEnabled)
                if config.burstDetectionEnabled {
                    SliderRow(label: config.localized("Burst FPS"),
                              value: intBinding($config.burstFps, in: 4...20),
                              range: 4...20,
                              display: "\(config.burstFps)")
                    Text(config.localized("Maximum frames-per-second gap for grouping consecutive frames as a burst. Higher values group more loosely."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SliderRow(label: config.localized("Min Burst Count"),
                              value: intBinding($config.burstMinCount, in: 2...10),
                              range: 2...10,
                              display: "\(config.burstMinCount)")
                    Text(config.localized("Minimum frames required to form a burst. Smaller groups are treated as singletons."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SliderRow(label: config.localized("Hash Tolerance"),
                              value: intBinding($config.burstHashTolerance, in: 4...30),
                              range: 4...30,
                              display: "\(config.burstHashTolerance)")
                    Text(config.localized("Perceptual-hash distance allowed within a burst. Higher tolerates more composition drift between frames."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings UI for the on-disk full-res JPEG cache that speeds up
/// keyboard navigation in zoom mode.
struct PreviewCacheSettings: View {
    @Environment(CullingConfig.self) private var config
    @State private var currentSize: Int64?
    @State private var isComputingSize = false
    @State private var showClearConfirm = false

    private static let sizeOptions: [Int] = [5, 20, 50, 100, 0]

    private var capLabel: String {
        config.previewCacheSizeGB == 0
            ? config.localized("Unlimited")
            : "\(config.previewCacheSizeGB) GB"
    }

    var body: some View {
        @Bindable var config = config
        Toggle(config.localized("Generate preview cache for faster zoom"),
               isOn: $config.generatePreviewCache)

        Picker(config.localized("Cache size"),
               selection: $config.previewCacheSizeGB) {
            ForEach(Self.sizeOptions, id: \.self) { gb in
                Text(gb == 0 ? config.localized("Unlimited") : "\(gb) GB").tag(gb)
            }
        }
        .accessibilityIdentifier("PreviewCache_SizePicker")

        HStack {
            Text(config.localized("Currently using"))
                .foregroundStyle(.secondary)
            Spacer()
            if isComputingSize {
                ProgressView().controlSize(.small)
            } else if let bytes = currentSize {
                Text("\(formatBytes(bytes)) / \(capLabel)")
                    .monospacedDigit()
                    .accessibilityIdentifier("PreviewCache_CurrentSize")
            } else {
                Text(config.localized("Calculating…"))
                    .foregroundStyle(.secondary)
            }
        }

        HStack {
            Spacer()
            Button(config.localized("Clear preview cache"), role: .destructive) {
                showClearConfirm = true
            }
            .accessibilityIdentifier("PreviewCache_ClearButton")
        }
        .confirmationDialog(
            config.localized("Clear all cached previews?"),
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button(config.localized("Clear"), role: .destructive) {
                _ = PreviewCache.clearAll()
                refreshSize()
            }
            Button(config.localized("Cancel"), role: .cancel) {}
        } message: {
            Text(config.localized("Cached previews will be regenerated next time you zoom into a photo."))
        }
        .task { refreshSize() }
        .onChange(of: config.previewCacheSizeGB) { _, _ in refreshSize() }
    }

    private func refreshSize() {
        isComputingSize = true
        Task.detached(priority: .utility) {
            let bytes = PreviewCache.currentSizeBytes()
            await MainActor.run {
                self.currentSize = bytes
                self.isComputingSize = false
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct SliderRow<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let label: String
    @Binding var value: V
    let range: ClosedRange<V>
    let display: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: $value, in: range)
                    .accessibilityIdentifier("SliderRow_\(label)_Slider")
                Text(display)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                    .accessibilityIdentifier("SliderRow_\(label)_Value")
            }
        } label: {
            Text(label)
        }
        .accessibilityIdentifier("SliderRow_\(label)")
    }
}

func snappedBinding(_ source: Binding<Float>, step: Float) -> Binding<Float> {
    Binding(
        get: { source.wrappedValue },
        set: { source.wrappedValue = (($0 / step).rounded() * step) }
    )
}

func snappedBinding(_ source: Binding<Double>, step: Double) -> Binding<Double> {
    Binding(
        get: { source.wrappedValue },
        set: { source.wrappedValue = (($0 / step).rounded() * step) }
    )
}

func intBinding(_ source: Binding<Int>, in range: ClosedRange<Int>) -> Binding<Double> {
    Binding(
        get: { Double(source.wrappedValue) },
        set: { source.wrappedValue = min(range.upperBound, max(range.lowerBound, Int($0.rounded()))) }
    )
}

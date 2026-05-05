import SwiftUI

struct ThresholdCalibratorView: View {
    let photo: Photo?
    @Environment(CullingConfig.self) private var config

    private var predictedRating: Int? {
        PhotoRatingPredictor.predict(
            photo: photo,
            config: RatingEngine.Config(
                sharpnessThreshold: config.sharpnessThreshold,
                aestheticsThreshold: config.aestheticsThreshold
            )
        )
    }

    var body: some View {
        @Bindable var config = config
        VStack(alignment: .leading, spacing: 0) {
            Text(config.localized("Calibrate Thresholds"))
                .font(.headline)
                .padding(.bottom, 12)

            ThresholdScoreRow(
                label: config.localized("Sharpness"),
                threshold: $config.sharpnessThreshold,
                range: 100...800,
                step: 10,
                photoValue: photo?.sharpnessScore,
                format: { "\(Int($0))" }
            )
            ThresholdScoreRow(
                label: config.localized("Aesthetics"),
                threshold: $config.aestheticsThreshold,
                range: 2.0...8.0,
                step: 0.1,
                photoValue: photo?.aestheticsScore,
                format: { String(format: "%.1f", $0) }
            )
            Divider().padding(.vertical, 10)

            if let rating = predictedRating {
                HStack(spacing: 6) {
                    Text(config.localized("Predicted:"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    StarRatingView(rating: rating)
                }
            } else if photo != nil {
                Text(config.localized("No bird detected"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text(config.localized("Select a processed photo"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct ThresholdScoreRow: View {
    @Environment(CullingConfig.self) private var config
    let label: String
    @Binding var threshold: Float
    let range: ClosedRange<Float>
    let step: Float
    let photoValue: Float?
    let format: (Float) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .frame(width: 65, alignment: .leading)
                Slider(value: $threshold, in: range, step: step)
                Text(format(threshold))
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
            HStack(spacing: 4) {
                Spacer().frame(width: 69)
                if let photoValue {
                    let passes = photoValue >= threshold
                    Image(systemName: passes ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(passes ? Color.green : Color.orange)
                    Text("\(config.localized("This photo:")) \(format(photoValue))")
                        .font(.caption2)
                        .foregroundStyle(passes ? Color.green : Color.orange)
                } else {
                    Text(config.localized("Not measured"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .frame(height: 14)
        }
        .padding(.bottom, 6)
    }
}

import SwiftUI

struct ThresholdCalibratorView: View {
    let photo: Photo?
    @Environment(CullingConfig.self) private var config

    private var predictedRating: Int? {
        guard let photo, let confidence = photo.birdConfidence else { return nil }
        let allKeypointsHidden = (photo.leftEyeVis ?? 0) < 0.3
            && (photo.rightEyeVis ?? 0) < 0.3
            && (photo.beakVis ?? 0) < 0.3
        let cfg = RatingEngine.Config(
            sharpnessThreshold: config.sharpnessThreshold,
            aestheticsThreshold: config.aestheticsThreshold
        )
        return RatingEngine().calculate(
            detected: true,
            confidence: confidence,
            sharpness: photo.sharpnessScore ?? 0,
            aesthetics: photo.aestheticsScore,
            allKeypointsHidden: allKeypointsHidden,
            isOverexposed: photo.exposureStatus == ExposureStatus.overexposed.rawValue,
            isUnderexposed: photo.exposureStatus == ExposureStatus.underexposed.rawValue,
            isFlying: photo.isFlying,
            config: cfg
        ).rating
    }

    var body: some View {
        @Bindable var config = config
        VStack(alignment: .leading, spacing: 0) {
            Text("Calibrate Thresholds")
                .font(.headline)
                .padding(.bottom, 12)

            ThresholdScoreRow(
                label: "Sharpness",
                threshold: $config.sharpnessThreshold,
                range: 100...800,
                step: 10,
                photoValue: photo?.sharpnessScore,
                format: { "\(Int($0))" }
            )
            ThresholdScoreRow(
                label: "Aesthetics",
                threshold: $config.aestheticsThreshold,
                range: 2.0...8.0,
                step: 0.1,
                photoValue: photo?.aestheticsScore,
                format: { String(format: "%.1f", $0) }
            )
            Divider().padding(.vertical, 10)

            if let rating = predictedRating {
                HStack(spacing: 6) {
                    Text("Predicted:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    StarRatingView(rating: rating)
                }
            } else if photo != nil {
                Text("No bird detected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Select a processed photo")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(width: 300)
    }
}

private struct ThresholdScoreRow: View {
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
                    Text("This photo: \(format(photoValue))")
                        .font(.caption2)
                        .foregroundStyle(passes ? Color.green : Color.orange)
                } else {
                    Text("Not measured")
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

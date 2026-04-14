import SwiftUI
import CoreGraphics

/// Progress-only sheet shown during folder processing.
struct ProcessingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let pipeline: PipelineCoordinator
    let folderName: String
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            if pipeline.isProcessing {
                progressView
            } else {
                doneView
            }
        }
        .padding(24)
        .frame(width: 400, height: 250)
        .accessibilityIdentifier("ProcessingSheet")
    }

    private var progressView: some View {
        VStack(spacing: 12) {
            Text("Processing \(folderName)")
                .font(.headline)
                .accessibilityIdentifier("ProcessingLabel")
            ProgressView(value: Double(pipeline.processedCount), total: Double(max(1, pipeline.totalCount)))
                .accessibilityIdentifier("ProcessingProgress")
            Text("\(pipeline.processedCount) / \(pipeline.totalCount)")
                .monospacedDigit()
                .accessibilityIdentifier("ProcessingCount")
            Text(pipeline.currentFilename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("CurrentFilename")
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .accessibilityIdentifier("CancelButton")
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Processing complete!")
                .font(.headline)
                .accessibilityIdentifier("ProcessingComplete")
            Button("Done") {
                onDone()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("DoneButton")
        }
    }
}

/// Mock inference client for UI testing — returns empty results quickly.
struct MockInferenceClientForUI: InferenceClient {
    func detect(image: CGImage) async throws -> DetectionResult { DetectionResult(birds: []) }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse { AestheticsResponse(score: 5.0, distribution: []) }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(leftEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       rightEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.9))
    }
    func flight(image: CGImage) async throws -> FlightResult { FlightResult(isFlying: false, confidence: 0.1) }
    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse { IdentifyResponse(species: [], birds: nil, totalDetected: nil) }
    func healthCheck() async throws -> ServerHealth { ServerHealth(status: "ready", modelsLoaded: [], device: "cpu", version: "1.0.0") }
}

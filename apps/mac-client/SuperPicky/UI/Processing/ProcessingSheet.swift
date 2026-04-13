import SwiftUI

struct ProcessingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CullingConfig.self) private var config
    @Environment(ProcessManager.self) private var processManager
    @State private var folderURL: URL?
    @State private var pipeline: PipelineCoordinator?
    @State private var processingTask: Task<Void, Never>?
    @State private var isDone = false
    @State private var errorMessage: String?

    let prefilledFolder: URL?
    let onComplete: (URL) -> Void

    private var isTestMode: Bool {
        ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
    }

    init(prefilledFolder: URL? = nil, onComplete: @escaping (URL) -> Void) {
        self.prefilledFolder = prefilledFolder
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 20) {
            if let pipeline, pipeline.isProcessing {
                progressView(pipeline)
            } else if isDone {
                doneView
            } else {
                selectionView
            }
        }
        .padding(24)
        .frame(width: 500, height: 350)
        .accessibilityIdentifier("ProcessingSheet")
        .onAppear {
            if let prefilledFolder {
                folderURL = prefilledFolder
            } else if let testFolder = ProcessInfo.processInfo.environment["TEST_FOLDER"] {
                folderURL = URL(fileURLWithPath: testFolder)
            }
        }
    }

    private var selectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if let folderURL {
                Text(folderURL.lastPathComponent)
                    .font(.headline)
                    .accessibilityIdentifier("FolderName")
            } else {
                Text("Select a folder to process")
                    .font(.headline)
                    .accessibilityIdentifier("SelectPrompt")
            }

            HStack {
                Button("Choose Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { folderURL = panel.url }
                }
                .accessibilityIdentifier("ChooseFolderButton")

                if folderURL != nil {
                    Button("Start Processing") { startProcessing() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("StartProcessingButton")
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .accessibilityIdentifier("ErrorMessage")
            }
        }
    }

    private func progressView(_ pipeline: PipelineCoordinator) -> some View {
        VStack(spacing: 12) {
            Text("Processing...")
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
                .accessibilityIdentifier("CurrentFilename")
            Button("Cancel") {
                processingTask?.cancel()
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
                if let url = folderURL { onComplete(url) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("DoneButton")
        }
    }

    private func startProcessing() {
        guard let folderURL else { return }

        // In test mode, bypass server check and use mock client
        guard isTestMode || processManager.isReady else {
            errorMessage = "Python server not ready"
            return
        }

        let client: InferenceClient
        if isTestMode {
            client = MockInferenceClientForUI()
        } else {
            client = HTTPInferenceClient(port: processManager.port)
        }

        let coord = PipelineCoordinator(inferenceClient: client)
        pipeline = coord

        let ratingConfig = RatingEngine.Config(
            sharpnessThreshold: config.sharpnessThreshold,
            aestheticsThreshold: config.aestheticsThreshold
        )
        let exposureEnabled = config.exposureDetectionEnabled
        let exposureThreshold = config.exposureThreshold
        let autoOrganize = config.autoOrganize

        processingTask = Task {
            await coord.process(
                folder: folderURL,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                autoOrganize: autoOrganize
            )
            isDone = true
            if !isTestMode { NSSound.beep() }
        }
    }
}

/// Mock inference client for UI testing — returns empty results quickly.
private struct MockInferenceClientForUI: InferenceClient {
    func detect(image: CGImage) async throws -> DetectionResult { DetectionResult(birds: []) }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse { AestheticsResponse(score: 5.0, distribution: []) }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(leftEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       rightEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.9))
    }
    func flight(image: CGImage) async throws -> FlightResult { FlightResult(isFlying: false, confidence: 0.1) }
    func identify(image: CGImage, topK: Int, temperature: Float) async throws -> [SpeciesMatch] { [] }
    func healthCheck() async throws -> ServerHealth { ServerHealth(status: "ready", modelsLoaded: [], device: "cpu", version: "1.0.0") }
}

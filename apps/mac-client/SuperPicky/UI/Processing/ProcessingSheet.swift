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
        .onAppear {
            if let prefilledFolder { folderURL = prefilledFolder }
        }
    }

    private var selectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            if let folderURL {
                Text(folderURL.lastPathComponent).font(.headline)
            } else {
                Text("Select a folder to process").font(.headline)
            }

            HStack {
                Button("Choose Folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { folderURL = panel.url }
                }
                if folderURL != nil {
                    Button("Start Processing") { startProcessing() }
                        .buttonStyle(.borderedProminent)
                }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.caption)
            }
        }
    }

    private func progressView(_ pipeline: PipelineCoordinator) -> some View {
        VStack(spacing: 12) {
            Text("Processing...").font(.headline)
            ProgressView(value: Double(pipeline.processedCount), total: Double(max(1, pipeline.totalCount)))
            Text("\(pipeline.processedCount) / \(pipeline.totalCount)").monospacedDigit()
            Text(pipeline.currentFilename).font(.caption).foregroundStyle(.secondary)
            Button("Cancel") {
                processingTask?.cancel()
                dismiss()
            }
        }
    }

    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Processing complete!").font(.headline)
            Button("Done") {
                if let url = folderURL { onComplete(url) }
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func startProcessing() {
        guard let folderURL, processManager.isReady else {
            errorMessage = processManager.isReady ? nil : "Python server not ready"
            return
        }

        let client = HTTPInferenceClient(port: processManager.port)
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
            NSSound.beep()
        }
    }
}

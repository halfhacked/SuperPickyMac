import Foundation
import Testing
@testable import SuperPickyInference

@Suite("ModelManager")
struct ModelManagerTests {
    @Test("ensureReady() on empty manifest returns .ready without errors")
    func emptyManifestReady() async throws {
        let manifest = ModelManifest(version: 1, models: [])
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superpicky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = ModelManager(manifest: manifest, rootDir: tmpDir)
        try await manager.ensureReady()

        let state = await manager.state
        switch state {
        case .ready:
            break // pass
        default:
            Issue.record("Expected .ready, got \(state)")
        }
    }

    @Test("Initial state is .notStarted")
    func initialState() async {
        let tmpDir = FileManager.default.temporaryDirectory
        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: tmpDir
        )
        let state = await manager.state
        switch state {
        case .notStarted:
            break // pass
        default:
            Issue.record("Expected .notStarted, got \(state)")
        }
    }

    @Test("ensureReady() is idempotent — second call emits no additional state changes")
    func idempotent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superpicky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: tmpDir
        )

        // First call: should transition to .ready
        try await manager.ensureReady()
        let firstState = await manager.state
        if case .ready = firstState { /* pass */ } else {
            Issue.record("Expected .ready after first ensureReady, got \(firstState)")
        }

        // Subscribe BETWEEN the two calls. Since state is already .ready,
        // the stream should emit .ready once (from observe's current-state
        // yield) and then finish immediately — NOT receive a second .ready
        // from the second ensureReady call.
        var emissions: [ModelManager.State] = []
        let streamTask = Task {
            for await state in await manager.observe() {
                emissions.append(state)
            }
            return emissions
        }

        // Second call: should be a no-op. If it's not, the stream above
        // would receive a SECOND .ready and `emissions.count` would be 2.
        try await manager.ensureReady()

        let finalEmissions = await streamTask.value
        #expect(finalEmissions.count == 1, "Expected exactly one .ready emission (the initial current-state yield). Got \(finalEmissions.count) emissions.")
        if let first = finalEmissions.first, case .ready = first {
            // pass
        } else {
            Issue.record("Expected first (and only) emission to be .ready, got \(finalEmissions)")
        }
    }

    @Test("observe() stream emits the current state and subsequent changes")
    func observeStream() async throws {
        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: FileManager.default.temporaryDirectory
        )

        let streamTask = Task {
            var seenReady = false
            for await state in await manager.observe() {
                if case .ready = state {
                    seenReady = true
                    break
                }
            }
            return seenReady
        }

        try await manager.ensureReady()
        let result = await streamTask.value
        #expect(result == true)
    }
}

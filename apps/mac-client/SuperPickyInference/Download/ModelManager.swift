// ModelManager.swift
//
// Actor that hydrates the bundled CoreML model scaffolds with their
// large weight.bin files on first launch.
//
// The app ships with complete .mlmodelc directories EXCEPT for the
// weights/weight.bin file inside each — those are downloaded (one flat
// file per model, no archives) to
//     ~/Library/Application Support/com.superpicky.mac/ModelCache/
// and verified against the SHA-256 listed in manifest.json.
//
// Flow per launch:
//   1. For each .mlmodelc scaffold in Bundle.module/Models/, copy it to
//      rootDir (skipping files that already exist).
//   2. For each manifest entry:
//      - If weight.bin is already at installPath, skip it.
//      - Else, download from entry.url, verify SHA-256, atomically move
//        into place.
//   3. Transition to .ready.
//
// Thread safety: actor; all mutable state is protected.

import Foundation
import CryptoKit
import os

public actor ModelManager {

    // MARK: - Public state

    public enum State: Sendable {
        case notStarted
        case copyingScaffolds
        case downloading(progress: Double, currentFile: String)
        case verifying(file: String)
        case ready
        case failed(Error)
    }

    public private(set) var state: State = .notStarted

    // MARK: - Private state

    private let manifest: ModelManifest
    private let rootDir: URL
    private let bundle: Bundle
    private var observers: [AsyncStream<State>.Continuation] = []
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "ModelManager")

    // MARK: - Init

    /// - Parameters:
    ///   - manifest: list of weight files to download
    ///   - rootDir: cache directory into which scaffolds are copied and
    ///     weights are downloaded (typically Application Support)
    ///   - bundle: resource bundle containing the .mlmodelc scaffolds;
    ///     defaults to the SuperPickyInference module bundle
    public init(manifest: ModelManifest,
                rootDir: URL,
                bundle: Bundle = .inferenceModule) {
        self.manifest = manifest
        self.rootDir = rootDir
        self.bundle = bundle
    }

    // MARK: - Public API

    /// Ensures every manifest weight file is on disk alongside its bundled
    /// scaffold. Idempotent — safe to call on every app launch.
    public func ensureReady() async throws {
        if case .ready = state { return }

        do {
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            setState(.copyingScaffolds)
            try copyScaffolds()
            try await downloadWeights()
            setState(.ready)
        } catch {
            logger.error("Model setup failed: \(error.localizedDescription)")
            setState(.failed(error))
            throw error
        }
    }

    /// Returns an `AsyncStream` that emits every state change.
    public func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            continuation.yield(state)
            if case .ready = state {
                continuation.finish()
                return
            }
            observers.append(continuation)
        }
    }

    // MARK: - Scaffold copy

    /// Copy the bundled .mlmodelc scaffolds into `rootDir`, skipping files
    /// that already exist. A few hundred KB total.
    /// SPM flattens `.copy()` resources, so the .mlmodelc directories live
    /// directly at the resource root rather than under a Models/ subdir.
    private func copyScaffolds() throws {
        let fm = FileManager.default
        guard let resourceRoot = bundle.resourceURL,
              fm.fileExists(atPath: resourceRoot.path) else {
            logger.warning("Inference bundle has no resourceURL; skipping scaffold copy")
            return
        }

        let entries = try fm.contentsOfDirectory(at: resourceRoot,
                                                  includingPropertiesForKeys: nil)
        for src in entries where src.pathExtension == "mlmodelc" {
            let dst = rootDir.appendingPathComponent(src.lastPathComponent)
            try mergeDirectory(from: src, to: dst)
        }
    }

    /// Recursively copy src into dst, creating parent directories as needed
    /// and skipping any files that already exist at the destination.
    private func mergeDirectory(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        }
        let items = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])
        for item in items {
            let dstItem = dst.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try mergeDirectory(from: item, to: dstItem)
            } else if !fm.fileExists(atPath: dstItem.path) {
                try fm.copyItem(at: item, to: dstItem)
            }
        }
    }

    // MARK: - Weight download

    private func downloadWeights() async throws {
        let total = manifest.models.count
        for (index, entry) in manifest.models.enumerated() {
            let dest = rootDir.appendingPathComponent(entry.installPath)

            if FileManager.default.fileExists(atPath: dest.path) {
                logger.info("[\(index+1)/\(total)] \(entry.id) already present")
                continue
            }

            let baseProgress = Double(index) / Double(total)
            let sliceSize = 1.0 / Double(total)
            setState(.downloading(progress: baseProgress, currentFile: entry.filename))

            let tmpFile = try await download(entry: entry) { [weak self] fraction in
                let p = baseProgress + fraction * sliceSize
                Task { await self?.setState(.downloading(progress: p,
                                                          currentFile: entry.filename)) }
            }
            defer { try? FileManager.default.removeItem(at: tmpFile) }

            setState(.verifying(file: entry.filename))
            try verify(fileURL: tmpFile, expectedSHA256: entry.sha256)

            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tmpFile, to: dest)

            logger.info("[\(index+1)/\(total)] \(entry.id) installed")
        }
    }

    private func download(entry: ModelEntry,
                          progress: @escaping (Double) -> Void) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent(UUID().uuidString + "_" + entry.filename)

        let (location, response) = try await URLSession.shared.downloadWithProgress(
            from: entry.url, progress: progress)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelManagerError.downloadFailed(entry.id, http.statusCode)
        }

        try FileManager.default.moveItem(at: location, to: tmpFile)
        return tmpFile
    }

    private func verify(fileURL: URL, expectedSHA256: String) throws {
        // Stream the file through SHA256 to avoid loading 250+ MB into RAM.
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20) // 1 MB
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256 else {
            throw ModelManagerError.checksumMismatch(expected: expectedSHA256, actual: hex)
        }
    }

    // MARK: - State plumbing

    private func setState(_ newState: State) {
        state = newState
        for continuation in observers {
            continuation.yield(newState)
        }
        if case .ready = newState {
            for continuation in observers { continuation.finish() }
            observers.removeAll()
        }
        if case .failed = newState {
            for continuation in observers { continuation.finish() }
            observers.removeAll()
        }
    }
}

// MARK: - Bundle accessor

public extension Bundle {
    /// The SuperPickyInference resource bundle. Resolves to `Bundle.module`
    /// under SPM, and a framework-anchored bundle under xcodebuild.
    static var inferenceModule: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: InferenceBundleAnchor.self)
        #endif
    }
}

/// Anchor used by `Bundle(for:)` to locate the framework resource bundle
/// when built via xcodebuild. SPM uses `Bundle.module` instead.
private final class InferenceBundleAnchor {}

// MARK: - URLSession download with progress

private extension URLSession {
    func downloadWithProgress(from url: URL,
                               progress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        return try await withCheckedThrowingContinuation { continuation in
            let task = self.downloadTask(with: url) { location, response, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location, let response else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                continuation.resume(returning: (location, response))
            }
            let observation = task.progress.observe(\.fractionCompleted) { p, _ in
                progress(p.fractionCompleted)
            }
            task.resume()
            _ = observation
        }
    }
}

// MARK: - Errors

public enum ModelManagerError: Error, LocalizedError {
    case downloadFailed(String, Int)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let id, let code):
            return "Download failed for \(id) (HTTP \(code))"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected.prefix(8))… got \(actual.prefix(8))…"
        }
    }
}

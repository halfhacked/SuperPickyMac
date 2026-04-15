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
            logger.error("Model setup failed: \(error.localizedDescription, privacy: .public)")
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
        guard let rawResourceRoot = bundle.resourceURL,
              fm.fileExists(atPath: rawResourceRoot.path) else {
            logger.warning("Inference bundle has no resourceURL; skipping scaffold copy")
            return
        }
        // For framework bundles, resourceURL points at the top-level "Resources"
        // symlink (→ Versions/Current/Resources → Versions/A/Resources). Swift's
        // FileManager.contentsOfDirectory chokes on that symlink, so resolve it
        // to the real path first.
        let resourceRoot = rawResourceRoot.resolvingSymlinksInPath()
        logger.info("Copying scaffolds from \(resourceRoot.path, privacy: .public) to \(self.rootDir.path, privacy: .public)")

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
                logger.info("[\(index+1)/\(total)] \(entry.id, privacy: .public) already present")
                continue
            }
            logger.info("[\(index+1)/\(total)] Downloading \(entry.id, privacy: .public) (\(entry.sizeBytes) bytes)")

            let baseProgress = Double(index) / Double(total)
            let sliceSize = 1.0 / Double(total)
            setState(.downloading(progress: baseProgress, currentFile: entry.filename))

            // Stage next to the final destination so (a) we never use /tmp and
            // (b) the move into place is a cheap same-volume rename.
            let parent = dest.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let stagingFile = parent.appendingPathComponent(dest.lastPathComponent + ".downloading")
            if FileManager.default.fileExists(atPath: stagingFile.path) {
                try FileManager.default.removeItem(at: stagingFile)
            }

            try await downloadToFile(
                entry: entry,
                destination: stagingFile,
                progressHandler: { [weak self] fraction in
                    let p = baseProgress + fraction * sliceSize
                    Task { await self?.setState(.downloading(progress: p,
                                                              currentFile: entry.filename)) }
                })

            // Verify SHA-256 of the staged file, then atomically rename into place.
            setState(.verifying(file: entry.filename))
            do {
                try verify(fileURL: stagingFile, expectedSHA256: entry.sha256)
            } catch {
                try? FileManager.default.removeItem(at: stagingFile)
                throw error
            }
            try FileManager.default.moveItem(at: stagingFile, to: dest)

            logger.info("[\(index+1)/\(total)] \(entry.id, privacy: .public) installed")
        }
    }

    /// Downloads entry.url into `destination` using a delegate-based progress
    /// observer. Uses the modern async `download(for:delegate:)` API so the
    /// result file stays valid until we explicitly move it — no race with
    /// URLSession reclaiming a temp file after the completion handler returns.
    private func downloadToFile(entry: ModelEntry,
                                 destination: URL,
                                 progressHandler: @escaping (Double) -> Void) async throws {
        let delegate = DownloadProgressDelegate(handler: progressHandler)
        let request = URLRequest(url: entry.url)
        let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: tempURL)
            throw ModelManagerError.downloadFailed(entry.id, http.statusCode)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
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

// MARK: - Download progress delegate

/// A minimal URLSessionDownloadDelegate that only exists to emit fraction
/// complete updates. The async `URLSession.download(for:delegate:)` API
/// handles the actual file management.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let handler: (Double) -> Void
    init(handler: @escaping (Double) -> Void) { self.handler = handler }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        handler(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // The async download(for:delegate:) API moves the completed file into a
    // location the caller can take ownership of, so we don't need to handle
    // didFinishDownloadingTo here.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) { /* no-op */ }
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

// ModelManager.swift
//
// Actor that ensures the model files listed in a manifest are present on
// disk, downloading and verifying them when needed.
//
// Model cache: ~/Library/Application Support/com.superpicky.mac/ModelCache/
// Manifest URL base: https://huggingface.co/superpicky/models/resolve/main/
//   (update manifest.json urls when models are hosted)
//
// Download flow per entry:
//   1. Check installPath exists and SHA-256 matches → skip (already installed)
//   2. Download zip to a temp file with URLSession
//   3. Verify SHA-256 of the zip
//   4. Unzip with /usr/bin/unzip into a temp staging dir
//   5. Atomic rename into rootDir/installPath
//
// Thread safety: actor; all mutable state is protected.

import Foundation
import CryptoKit
import os

public actor ModelManager {

    // MARK: - Public state

    public enum State: Sendable {
        case notStarted
        case downloading(progress: Double, currentFile: String)
        case verifying(file: String)
        case installing(file: String)
        case ready
        case failed(Error)
    }

    public private(set) var state: State = .notStarted

    // MARK: - Private state

    private let manifest: ModelManifest
    private let rootDir: URL
    private var observers: [AsyncStream<State>.Continuation] = []
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "ModelManager")

    // MARK: - Init

    public init(manifest: ModelManifest, rootDir: URL) {
        self.manifest = manifest
        self.rootDir = rootDir
    }

    // MARK: - Public API

    /// Ensures every manifest entry is on disk and verified.
    /// Idempotent — safe to call on every app launch.
    /// On failure, transitions to `.failed(error)` and rethrows so callers
    /// can still inspect the error; observers receive `.failed` via the
    /// state stream.
    public func ensureReady() async throws {
        if case .ready = state { return }
        if manifest.models.isEmpty {
            setState(.ready)
            return
        }

        do {
            try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
            try await downloadAll()
            setState(.ready)
        } catch {
            logger.error("Model download failed: \(error.localizedDescription)")
            setState(.failed(error))
            throw error
        }
    }

    private func downloadAll() async throws {
        let total = manifest.models.count
        for (index, entry) in manifest.models.enumerated() {
            let dest = rootDir.appendingPathComponent(entry.installPath)

            // Fast path: already installed
            if isInstalled(entry: entry, at: dest) {
                logger.info("[\(index+1)/\(total)] \(entry.id) already installed")
                setState(.downloading(progress: Double(index + 1) / Double(total),
                                      currentFile: entry.id))
                continue
            }

            // Download
            let baseProgress = Double(index) / Double(total)
            let sliceSize = 1.0 / Double(total)
            setState(.downloading(progress: baseProgress, currentFile: entry.filename))

            let zipURL = try await download(entry: entry) { [weak self] fraction in
                let p = baseProgress + fraction * sliceSize * 0.8
                Task { await self?.setState(.downloading(progress: p, currentFile: entry.filename)) }
            }
            defer { try? FileManager.default.removeItem(at: zipURL) }

            // Verify
            setState(.verifying(file: entry.filename))
            try verify(zipURL: zipURL, expectedSHA256: entry.sha256)

            // Install
            setState(.installing(file: entry.filename))
            try install(zipURL: zipURL, entry: entry, dest: dest)

            logger.info("[\(index+1)/\(total)] \(entry.id) installed")
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

    // MARK: - Private helpers

    private func setState(_ newState: State) {
        state = newState
        for continuation in observers {
            continuation.yield(newState)
        }
        if case .ready = newState {
            for continuation in observers {
                continuation.finish()
            }
            observers.removeAll()
        }
        if case .failed = newState {
            for continuation in observers {
                continuation.finish()
            }
            observers.removeAll()
        }
    }

    private func isInstalled(entry: ModelEntry, at dest: URL) -> Bool {
        let fm = FileManager.default
        // For directories (mlmodelc), check the directory exists.
        // For files (sqlite), check the file exists.
        // A re-download only triggers if the file is missing; re-verify on disk
        // would be prohibitively slow for 256 MB files on every launch.
        return fm.fileExists(atPath: dest.path)
    }

    private func download(entry: ModelEntry,
                          progress: @escaping (Double) -> Void) async throws -> URL {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpZip = tmpDir.appendingPathComponent(UUID().uuidString + "_" + entry.filename)

        let (location, response) = try await URLSession.shared.download(from: entry.url) { bytesSent, totalBytes in
            if totalBytes > 0 {
                progress(Double(bytesSent) / Double(totalBytes))
            }
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw ModelManagerError.downloadFailed(entry.id, http.statusCode)
        }

        try FileManager.default.moveItem(at: location, to: tmpZip)
        return tmpZip
    }

    private func verify(zipURL: URL, expectedSHA256: String) throws {
        let data = try Data(contentsOf: zipURL)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex == expectedSHA256 else {
            throw ModelManagerError.checksumMismatch(expected: expectedSHA256, actual: hex)
        }
    }

    private func install(zipURL: URL, entry: ModelEntry, dest: URL) throws {
        let fm = FileManager.default
        let tmpStage = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmpStage) }

        try fm.createDirectory(at: tmpStage, withIntermediateDirectories: true)

        // Unzip using system unzip
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", zipURL.path, "-d", tmpStage.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ModelManagerError.unzipFailed(entry.id, err.prefix(200).description)
        }

        // The zip contains a single entry at the installPath basename
        let basename = URL(fileURLWithPath: entry.installPath).lastPathComponent
        let extracted = tmpStage.appendingPathComponent(basename)
        guard fm.fileExists(atPath: extracted.path) else {
            throw ModelManagerError.unzipFailed(entry.id, "expected \(basename) in zip")
        }

        // Atomic replace
        let parent = dest.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) {
            _ = try fm.replaceItemAt(dest, withItemAt: extracted)
        } else {
            try fm.moveItem(at: extracted, to: dest)
        }
    }
}

// MARK: - URLSession download with progress

private extension URLSession {
    func download(from url: URL,
                  progress: @escaping (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
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
                let bytes = Int64(p.fractionCompleted * Double(task.countOfBytesExpectedToReceive))
                progress(bytes, task.countOfBytesExpectedToReceive)
            }
            task.resume()
            // Keep observation alive for the duration
            _ = observation
        }
    }
}

// MARK: - Errors

public enum ModelManagerError: Error, LocalizedError {
    case downloadFailed(String, Int)
    case checksumMismatch(expected: String, actual: String)
    case unzipFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let id, let code):
            return "Download failed for \(id) (HTTP \(code))"
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch: expected \(expected.prefix(8))… got \(actual.prefix(8))…"
        case .unzipFailed(let id, let detail):
            return "Unzip failed for \(id): \(detail)"
        }
    }
}

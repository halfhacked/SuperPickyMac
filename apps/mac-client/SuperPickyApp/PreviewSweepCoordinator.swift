import Foundation
import os

/// Walks a folder's photos in display order after open and pre-generates
/// any missing PreviewCache JPEGs. Sweep is paused during user interaction
/// so foreground decodes never compete with background work, and is
/// cancelled on folder change / app quit.
@MainActor
final class PreviewSweepCoordinator {
    static let shared = PreviewSweepCoordinator()
    private static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "PreviewSweep")

    /// Window after the last interaction during which the sweep yields.
    private static let interactionGrace: TimeInterval = 2.0

    private var task: Task<Void, Never>?
    private var processing: Set<String> = []
    private var lastInteraction: Date = .distantPast

    /// Start a sweep over `paths`. Cancels any in-flight sweep first.
    /// `paths` should already be ordered as the user will see them so
    /// nearby photos are warmed first.
    func start(folder: URL, paths: [String]) {
        stop()
        guard ImageLoader.generatePreviewCache, !paths.isEmpty else { return }
        task = Task { [weak self] in
            await self?.run(folder: folder, paths: paths)
        }
    }

    /// Cancel and forget the in-flight sweep.
    func stop() {
        task?.cancel()
        task = nil
        processing.removeAll()
    }

    /// Whether the sweep is currently writing a cache entry for `path`.
    /// Used by the prefetch coordinator to avoid double work.
    func isProcessing(path: String) -> Bool { processing.contains(path) }

    /// Note that the user is actively driving the UI (key event, click).
    /// The sweep yields for `interactionGrace` seconds after each note.
    func noteInteraction() { lastInteraction = Date() }

    // MARK: - Sweep body

    private func run(folder: URL, paths: [String]) async {
        let started = Date()
        var written = 0
        var skipped = 0
        let cap = PreviewCache.settings.capBytes
        for path in paths {
            if Task.isCancelled { break }

            while shouldYield() {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }

            if PreviewCache.freshURL(for: path) != nil { skipped += 1; continue }

            processing.insert(path)
            _ = await ImageLoader.loadCGImageBackground(path: path, maxPixelSize: nil)
            processing.remove(path)
            written += 1

            if cap > 0, written.isMultiple(of: 20) {
                PreviewCache.evictIfOverCap(maxBytes: cap)
            }

            await Task.yield()
        }
        let elapsed = Date().timeIntervalSince(started)
        Self.log.info("folder=\(folder.path) wrote=\(written) skipped=\(skipped) elapsed=\(elapsed, privacy: .public)s")
    }

    private func shouldYield() -> Bool {
        Date().timeIntervalSince(lastInteraction) < Self.interactionGrace
    }
}

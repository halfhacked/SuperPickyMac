import Foundation
import AppKit
import os

/// Pre-warms `ImageCache.fullRes` for the next photos in the user's nav
/// direction so holding arrow stays smooth in zoom mode.
///
/// Direction is inferred from the previous-vs-current index. Forward nav
/// prefetches `i+1, i+2`; backward nav prefetches `i-1, i-2`. Each call
/// cancels the prior prefetch tasks before scheduling new ones, so a fast
/// scrubber never piles up work.
@MainActor
final class PrefetchCoordinator {
    static let shared = PrefetchCoordinator()
    private static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")

    private static let radius = 2

    private var lastIndex: Int?
    private var inflight: [Task<Void, Never>] = []

    /// Call from the view that owns the selection, on selection change.
    /// `zoomActive` should be `true` only when the view is currently
    /// rendering at scale > 1.0 — at fit scale, the working set is the
    /// 2000-px preview cache, which is much cheaper.
    func update(currentIndex: Int, photos: [Photo], zoomActive: Bool) {
        cancelAll()
        defer { lastIndex = currentIndex }

        guard zoomActive, photos.indices.contains(currentIndex) else { return }
        guard let prior = lastIndex else { return }

        let direction = currentIndex - prior
        guard direction != 0 else { return }
        let step = direction > 0 ? 1 : -1

        for i in 1...Self.radius {
            let target = currentIndex + step * i
            guard photos.indices.contains(target) else { break }
            let path = photos[target].filePath
            if ImageCache.fullRes.get(path) != nil { continue }
            scheduleWarm(path: path)
        }
    }

    /// Stop all in-flight prefetch tasks (folder change, app quit).
    func reset() {
        cancelAll()
        lastIndex = nil
    }

    private func scheduleWarm(path: String) {
        let task = Task.detached(priority: .utility) {
            guard let cgImage = await ImageLoader.loadCGImageBackground(path: path) else { return }
            await MainActor.run {
                let image = NSImage(cgImage: cgImage,
                                    size: NSSize(width: cgImage.width, height: cgImage.height))
                ImageCache.fullRes.set(path, image: image)
            }
        }
        inflight.append(task)
    }

    private func cancelAll() {
        for t in inflight { t.cancel() }
        inflight.removeAll()
    }
}

import Foundation
import AppKit
import os

/// Pre-warms `ImageCache.fullRes` for the photos the user is most likely
/// to view next in zoom mode.
///
/// Priority order (matches the user's typical zoom-mode workflow of
/// comparing similar shots within a burst, then moving to the next):
///   1. Same-burst photos (excluding the current photo) — chronological.
///   2. The next-or-previous burst in display order, taking nav direction
///      from the prior-vs-current index.
///
/// Each call cancels the prior prefetch tasks before scheduling new ones.
@MainActor
final class PrefetchCoordinator {
    static let shared = PrefetchCoordinator()
    fileprivate static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")

    /// Cap how many prefetches we schedule per update so we don't blow past
    /// `ImageCache.fullRes` (countLimit=8) and evict the freshly-warmed entries.
    private static let budget = 6

    /// How many photos from the next burst to prefetch. Same-burst photos
    /// already get unlimited prefetch — the next burst is a smaller bet.
    private static let nextBurstDepth = 3

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
        let current = photos[currentIndex]

        // Direction defaults to forward when we have no prior selection
        // (the user just zoomed in cold).
        let step: Int
        if let prior = lastIndex, prior != currentIndex {
            step = currentIndex > prior ? 1 : -1
        } else {
            step = 1
        }

        var targets: [Photo] = []

        if let bid = current.burstGroupID {
            let same = photos.filter { $0.burstGroupID == bid && $0.id != current.id }
                .sorted { $0.dateCreated < $1.dateCreated }
            targets.append(contentsOf: same)
        }

        let nextBurst = adjacentBurstPhotos(from: currentIndex, in: photos, step: step)
        targets.append(contentsOf: nextBurst.prefix(Self.nextBurstDepth))

        let scheduled = targets.prefix(Self.budget)
        Self.log.info(
            "update idx=\(currentIndex) step=\(step) burst=\(current.burstGroupID?.uuidString.prefix(4) ?? "—", privacy: .public) targets=\(scheduled.map { ($0.filePath as NSString).lastPathComponent }.joined(separator: ","), privacy: .public)"
        )

        for photo in scheduled {
            if ImageCache.fullRes.get(photo.filePath) != nil { continue }
            scheduleWarm(path: photo.filePath)
        }
    }

    /// Stop all in-flight prefetch tasks (folder change, app quit).
    func reset() {
        cancelAll()
        lastIndex = nil
    }

    /// Walk along `photos` from `index` in `step` direction until the
    /// burstGroupID changes, then collect that next burst's contiguous
    /// members. Singletons (nil burst) count as a burst of size 1.
    /// Returned photos are in display order along `step` (so the
    /// chronologically-nearest one is first).
    private func adjacentBurstPhotos(from index: Int, in photos: [Photo], step: Int) -> [Photo] {
        let currentBurst = photos[index].burstGroupID
        var i = index + step
        while photos.indices.contains(i) {
            if photos[i].burstGroupID == currentBurst, currentBurst != nil {
                i += step
                continue
            }
            let nbid = photos[i].burstGroupID
            var collected: [Photo] = [photos[i]]
            if nbid == nil { return collected }
            var j = i + step
            while photos.indices.contains(j) {
                guard photos[j].burstGroupID == nbid else { break }
                collected.append(photos[j])
                j += step
            }
            return collected
        }
        return []
    }

    private func scheduleWarm(path: String) {
        let task = Task.detached(priority: .utility) {
            guard let cgImage = await ImageLoader.loadCGImagePrefetch(path: path) else { return }
            await MainActor.run {
                let image = NSImage(cgImage: cgImage,
                                    size: NSSize(width: cgImage.width, height: cgImage.height))
                ImageCache.fullRes.set(path, image: image)
                Self.log.info("warmed RAM \((path as NSString).lastPathComponent, privacy: .public)")
            }
        }
        inflight.append(task)
    }

    private func cancelAll() {
        for t in inflight { t.cancel() }
        inflight.removeAll()
    }
}

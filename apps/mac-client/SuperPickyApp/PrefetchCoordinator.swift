import Foundation
import AppKit
import os

/// Maintains a working set of full-resolution decodes in `ImageCache.fullRes`
/// optimised for culling: the user's current burst stays warm, plus a few of
/// the next bursts in their navigation direction. Direction is detected from
/// a "streak" of consecutive same-direction moves; longer streaks reach
/// further ahead.
///
/// Anti-thrash discipline: every update diffs the desired target set against
/// in-flight tasks. Already-cached or already-in-flight paths are not
/// re-scheduled, and only tasks whose paths fell out of the new target set
/// get cancelled. Walking from photo N to N+1 in a 10-photo burst keeps the
/// other 9 prefetches running unchanged.
@MainActor
final class PrefetchCoordinator {
    static let shared = PrefetchCoordinator()
    fileprivate static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")

    /// Baseline number of photos to prefetch from bursts beyond the current
    /// one. Grows with the user's direction streak.
    private static let baseNextBurstDepth = 6
    /// Hard ceiling so a long streak doesn't blow past the in-RAM cache.
    private static let maxNextBurstDepth = 30

    /// Streak counter: positive = consecutive forward moves, negative =
    /// backward. Magnitude reaches further into next bursts in that
    /// direction; reversal resets to ±1.
    private var streak: Int = 0
    private var lastIndex: Int?

    /// In-flight prefetch tasks keyed by file path. Diffed against the
    /// newest target set on each update so we don't churn through cancel /
    /// reschedule cycles for paths that are still wanted.
    private var inflight: [String: Task<Void, Never>] = [:]

    /// Kick off the initial RAM-cache fill right after a folder loads,
    /// before the user has navigated. Treats the auto-selected photo as
    /// the centre with no streak.
    func prefill(photos: [Photo], around index: Int) {
        guard photos.indices.contains(index) else { return }
        streak = 0
        lastIndex = nil
        update(currentIndex: index, photos: photos)
    }

    /// Recentre the working set on a new selection. Always runs (no longer
    /// gated on zoom mode), since culling at fit scale is also faster when
    /// the next zoomed photo is already decoded in RAM.
    func update(currentIndex: Int, photos: [Photo]) {
        guard photos.indices.contains(currentIndex) else { return }

        let step = updateStreak(currentIndex: currentIndex)
        lastIndex = currentIndex
        let current = photos[currentIndex]

        var targets: [String] = []

        if current.burstGroupID != nil {
            let same = sameBurstSortedByNavDistance(in: photos, currentIndex: currentIndex, step: step)
            targets.append(contentsOf: same.map(\.filePath))
        }

        // Streak boost: each consecutive same-direction move adds two
        // photos of next-burst depth, capped at maxNextBurstDepth.
        let streakMagnitude = abs(streak)
        let depthBoost = max(0, streakMagnitude - 1) * 2
        let nextDepth = min(Self.maxNextBurstDepth, Self.baseNextBurstDepth + depthBoost)
        let nextBurstPhotos = nextBurstsPhotos(from: currentIndex, in: photos, step: step, depth: nextDepth)
        targets.append(contentsOf: nextBurstPhotos.map(\.filePath))

        let capped = Array(targets.prefix(Self.maxTargets))
        let desired = Set(capped)

        // Cancel in-flight tasks whose paths are no longer wanted.
        var cancelled = 0
        for (path, task) in inflight where !desired.contains(path) {
            task.cancel()
            inflight.removeValue(forKey: path)
            cancelled += 1
        }

        // Schedule new targets we don't already have or aren't already
        // fetching.
        var scheduled = 0
        for path in capped {
            if inflight[path] != nil { continue }
            if ImageCache.fullRes.get(path) != nil { continue }
            scheduleWarm(path: path)
            scheduled += 1
        }

        Self.log.info(
            "update idx=\(currentIndex) step=\(step) streak=\(self.streak) burst=\(current.burstGroupID?.uuidString.prefix(4) ?? "—", privacy: .public) targets=\(capped.count) cancelled=\(cancelled) scheduled=\(scheduled) inflight=\(self.inflight.count)"
        )
    }

    /// Stop everything and reset the streak. Folder change, app quit.
    func reset() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        lastIndex = nil
        streak = 0
    }

    // MARK: - Internals

    /// Updates `streak` based on the move from `lastIndex` to
    /// `currentIndex` and returns the step direction (+1 / -1) to use for
    /// target ordering.
    private func updateStreak(currentIndex: Int) -> Int {
        guard let prior = lastIndex else {
            // First call after prefill — no history, default forward.
            return 1
        }
        let delta = currentIndex - prior
        if delta == 0 {
            // Same selection (filter change, refresh) — keep prior direction.
            return streak >= 0 ? 1 : -1
        }
        let dir = delta > 0 ? 1 : -1
        if (streak >= 0) == (dir > 0) {
            // Continuing in same direction — extend streak.
            streak += dir
        } else {
            // Reversal — restart streak in new direction.
            streak = dir
        }
        return dir
    }

    /// Cap how many photos we ever queue at once. Above this, churning
    /// through prefetches costs more than the cache hits save.
    private static let maxTargets = 40

    /// Photos that share the current burst, ordered by display distance in
    /// nav direction (ahead first, closer wins; behind as fallback).
    private func sameBurstSortedByNavDistance(in photos: [Photo], currentIndex: Int, step: Int) -> [Photo] {
        let bid = photos[currentIndex].burstGroupID
        let candidates = photos.enumerated()
            .filter { $0.offset != currentIndex && $0.element.burstGroupID == bid }
        return candidates.sorted { a, b in
            let signedA = (a.offset - currentIndex) * step
            let signedB = (b.offset - currentIndex) * step
            if (signedA > 0) != (signedB > 0) { return signedA > 0 }
            return abs(a.offset - currentIndex) < abs(b.offset - currentIndex)
        }.map(\.element)
    }

    /// Collect up to `depth` photos from the bursts immediately following
    /// (or preceding) the current one, in `step` direction. Skips past the
    /// current burst's tail; gathers contiguous members of each subsequent
    /// burst until `depth` is filled.
    private func nextBurstsPhotos(from index: Int, in photos: [Photo], step: Int, depth: Int) -> [Photo] {
        let currentBurst = photos[index].burstGroupID
        var collected: [Photo] = []
        var i = index + step
        var skippingCurrent = currentBurst != nil

        while photos.indices.contains(i), collected.count < depth {
            let pBurst = photos[i].burstGroupID
            if skippingCurrent, pBurst == currentBurst {
                i += step
                continue
            }
            skippingCurrent = false
            collected.append(photos[i])
            i += step
        }
        return collected
    }

    private func scheduleWarm(path: String) {
        let task = Task.detached(priority: .utility) {
            let cgImage = await ImageLoader.loadCGImagePrefetch(path: path)
            await MainActor.run {
                if let cgImage {
                    let image = NSImage(cgImage: cgImage,
                                        size: NSSize(width: cgImage.width, height: cgImage.height))
                    ImageCache.fullRes.set(path, image: image)
                    Self.log.debug("warmed RAM \((path as NSString).lastPathComponent, privacy: .public)")
                }
                PrefetchCoordinator.shared.inflightDidComplete(path: path)
            }
        }
        inflight[path] = task
    }

    fileprivate func inflightDidComplete(path: String) {
        inflight.removeValue(forKey: path)
    }
}

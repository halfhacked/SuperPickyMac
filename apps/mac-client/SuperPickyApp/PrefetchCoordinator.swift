import Foundation
import AppKit
import os

/// Indirection for the prefetch warming + cache-hit check. Production uses
/// `LiveImageCacheSink`, which decodes via `ImageLoader.loadCGImagePrefetch`
/// and writes to `ImageCache.fullRes`. Tests pass a recorder so the
/// orchestration (cancel/schedule/diff) can be exercised without ImageIO.
@MainActor
protocol PrefetchSink {
    func has(_ path: String) -> Bool
    func warm(_ path: String) -> Task<Void, Never>
}

/// Production sink: decodes via `ImageLoader.loadCGImagePrefetch` and
/// stores the result in `ImageCache.fullRes`. Stateless — safe to share.
@MainActor
struct LiveImageCacheSink: PrefetchSink {
    func has(_ path: String) -> Bool { ImageCache.fullRes.get(path) != nil }

    func warm(_ path: String) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            let cgImage = await ImageLoader.loadCGImagePrefetch(path: path)
            if let cgImage {
                await MainActor.run {
                    let image = NSImage(cgImage: cgImage,
                                        size: NSSize(width: cgImage.width, height: cgImage.height))
                    ImageCache.fullRes.set(path, image: image)
                    PrefetchCoordinator.log.debug("warmed RAM \((path as NSString).lastPathComponent, privacy: .public)")
                }
            }
        }
    }
}

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
    static let shared = PrefetchCoordinator(sink: LiveImageCacheSink())
    static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")

    private let sink: PrefetchSink

    init(sink: PrefetchSink) {
        self.sink = sink
    }

    /// Wire the dwell hook on `NavigationStateMonitor`. Must be called
    /// once at app launch from `SuperPickyApp.onAppear`, before any
    /// selection change can fire — otherwise the first dwell would
    /// silently no-op. Routes the monitor's dwell-fire to `update()`
    /// with the latest captured (currentIndex, photos).
    func bootstrap() {
        NavigationStateMonitor.shared.onEnterDwell = { [weak self] index, photos in
            self?.update(currentIndex: index, photos: photos)
        }
    }

    /// Baseline number of photos to prefetch from bursts beyond the current
    /// one. Grows with the user's direction streak.
    nonisolated private static let baseNextBurstDepth = 6
    /// Hard ceiling so a long streak doesn't blow past the in-RAM cache.
    nonisolated private static let maxNextBurstDepth = 30

    /// Streak counter: positive = consecutive forward moves, negative =
    /// backward. Magnitude reaches further into next bursts in that
    /// direction; reversal resets to ±1.
    private var streak: Int = 0
    private var lastIndex: Int?

    /// In-flight prefetch tasks keyed by file path. Diffed against the
    /// newest target set on each update so we don't churn through cancel /
    /// reschedule cycles for paths that are still wanted.
    private var inflight: [String: Task<Void, Never>] = [:]

    /// Cap how many photos we ever queue at once. Above this, churning
    /// through prefetches costs more than the cache hits save.
    nonisolated static let maxTargets = 40

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

        let (newStreak, step, targets) = Self.computeTargets(
            currentIndex: currentIndex, photos: photos,
            lastIndex: lastIndex, streak: streak
        )
        streak = newStreak
        lastIndex = currentIndex

        let desired = Set(targets)
        var cancelled = 0
        for (path, task) in inflight where !desired.contains(path) {
            task.cancel()
            inflight.removeValue(forKey: path)
            cancelled += 1
        }

        var scheduled = 0
        for path in targets {
            if inflight[path] != nil { continue }
            if sink.has(path) { continue }
            let inner = sink.warm(path)
            // Wrap so completion bookkeeping stays here, not in the sink.
            // Forward cancellation to the inner sink task so dropped
            // targets (and reset()) actually stop the underlying work.
            inflight[path] = Task { @MainActor [weak self] in
                await withTaskCancellationHandler {
                    _ = await inner.value
                } onCancel: {
                    inner.cancel()
                }
                self?.inflight.removeValue(forKey: path)
            }
            scheduled += 1
        }

        let current = photos[currentIndex]
        Self.log.info(
            "update idx=\(currentIndex) step=\(step) streak=\(self.streak) burst=\(current.burstGroupID?.uuidString.prefix(4) ?? "—", privacy: .public) targets=\(targets.count) cancelled=\(cancelled) scheduled=\(scheduled) inflight=\(self.inflight.count)"
        )
    }

    /// Stop everything and reset the streak. Folder change, app quit.
    func reset() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        lastIndex = nil
        streak = 0
    }

    // MARK: - Pure helpers

    /// Pure: derives the next streak, navigation step, and ordered prefetch
    /// target list for a given selection. No I/O, no actor hops, no
    /// observable side effects — fully testable.
    nonisolated static func computeTargets(
        currentIndex: Int,
        photos: [Photo],
        lastIndex: Int?,
        streak: Int
    ) -> (newStreak: Int, step: Int, targets: [String]) {
        guard photos.indices.contains(currentIndex) else {
            return (streak, 1, [])
        }

        let (newStreak, step) = nextStreak(currentIndex: currentIndex,
                                           lastIndex: lastIndex,
                                           streak: streak)
        let current = photos[currentIndex]
        var targets: [String] = []

        if current.burstGroupID != nil {
            let same = sameBurstSortedByNavDistance(in: photos,
                                                    currentIndex: currentIndex,
                                                    step: step)
            targets.append(contentsOf: same.map(\.filePath))
        }

        let streakMagnitude = abs(newStreak)
        let depthBoost = max(0, streakMagnitude - 1) * 2
        let nextDepth = min(maxNextBurstDepth, baseNextBurstDepth + depthBoost)
        let nextBurstPhotos = nextBurstsPhotos(from: currentIndex,
                                               in: photos,
                                               step: step,
                                               depth: nextDepth)
        targets.append(contentsOf: nextBurstPhotos.map(\.filePath))

        let capped = Array(targets.prefix(maxTargets))
        return (newStreak, step, capped)
    }

    /// Pure: streak update + navigation step direction.
    nonisolated private static func nextStreak(currentIndex: Int, lastIndex: Int?, streak: Int) -> (Int, Int) {
        guard let prior = lastIndex else { return (streak, 1) }
        let delta = currentIndex - prior
        if delta == 0 { return (streak, streak >= 0 ? 1 : -1) }
        let dir = delta > 0 ? 1 : -1
        let newStreak: Int
        if (streak >= 0) == (dir > 0) {
            newStreak = streak + dir
        } else {
            newStreak = dir
        }
        return (newStreak, dir)
    }

    /// Same-burst photos ordered by display distance in nav direction.
    nonisolated private static func sameBurstSortedByNavDistance(in photos: [Photo],
                                                                 currentIndex: Int,
                                                                 step: Int) -> [Photo] {
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

    /// Photos from the bursts immediately following (or preceding) the
    /// current one, in `step` direction, capped at `depth`. Skips past
    /// the current burst's tail.
    nonisolated private static func nextBurstsPhotos(from index: Int,
                                                     in photos: [Photo],
                                                     step: Int,
                                                     depth: Int) -> [Photo] {
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
}

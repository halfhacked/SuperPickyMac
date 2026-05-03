import Foundation
import AppKit
import os

/// Pure helper that derives the in-RAM `ImageCache.fullRes` byte/count
/// budget from the host machine's physical RAM and the user's "aggressive
/// cache" preference. Extracted as a free helper so tests can exercise the
/// full memory range without standing up a real Mac.
enum ImageCacheBudget {
    /// Approx. eager-decoded ARW (6000×4000 × 4 bytes/px ≈ 96 MB). Used
    /// to translate the byte budget into an entry count.
    static let estimatedEntryBytes = 96 * 1024 * 1024

    /// Memory-budget floor (per device) and ceiling. Floor keeps the
    /// 16 GB-Mac experience at least as good as the previous static
    /// 800 MB cap. Ceiling avoids starving other apps on workstation
    /// macs with hundreds of GB of RAM.
    static let minBytes = 800 * 1024 * 1024
    static let maxBytes = 32 * 1024 * 1024 * 1024  // 32 GB

    /// Resolve the cache budget. "Aggressive" uses 50% of physical RAM,
    /// "balanced" (default) uses 25%. Both clamp to [minBytes, maxBytes].
    static func compute(physicalMemory: UInt64, aggressive: Bool) -> (count: Int, bytes: Int) {
        let fraction = aggressive ? 0.5 : 0.25
        let raw = Int(Double(physicalMemory) * fraction)
        let bytes = max(minBytes, min(maxBytes, raw))
        let count = max(8, bytes / estimatedEntryBytes)
        return (count, bytes)
    }
}

/// NSCache wrapper keyed by file path. `preview` holds many small 2000 px
/// decodes; `fullRes` holds full-resolution eager-decoded bitmaps to keep
/// zoom-mode navigation instant. Both caches are shared between
/// `PreviewView`, `FullscreenViewer`, and `PrefetchCoordinator` so
/// back-arrow nav reuses cached frames regardless of which surface
/// decoded them.
///
/// `fullRes` is sized off `ProcessInfo.physicalMemory` so 64+ GB Macs
/// can hold hundreds of full-res bitmaps and treat re-visits within the
/// folder as zero-cost. 16 GB Macs still get the previous 800 MB / 8
/// entry floor.
final class ImageCache {
    static let preview = ImageCache(name: "preview", countLimit: 10, byteLimit: 400 * 1024 * 1024)
    static let fullRes: ImageCache = {
        let budget = ImageCacheBudget.compute(
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            aggressive: PreviewCache.settings.aggressiveCache
        )
        Logger.imageCache.info(
            "fullRes budget: \(budget.count) entries, \(budget.bytes / (1024 * 1024)) MB (physical=\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB) aggressive=\(PreviewCache.settings.aggressiveCache, privacy: .public)"
        )
        return ImageCache(name: "fullRes", countLimit: budget.count, byteLimit: budget.bytes)
    }()

    /// Re-apply the budget at runtime when the Settings toggle flips. Cheap
    /// — NSCache will lazily evict any entries that exceed the new caps.
    /// Also clamp the bookkeeping mirror to the new limits so the Settings
    /// readout doesn't briefly show "200 / 80 entries" after a shrink.
    func resize(countLimit: Int, byteLimit: Int) {
        cache.countLimit = countLimit
        cache.totalCostLimit = byteLimit
        bookkeeping.withLock { state in
            state.count = min(state.count, countLimit)
            state.bytes = min(state.bytes, byteLimit)
        }
        Logger.imageCache.info("resize \(self.name, privacy: .public): \(countLimit) entries, \(byteLimit / (1024 * 1024)) MB")
    }

    let name: String
    private let cache = NSCache<NSString, NSImage>()
    private let delegate: ImageCacheDelegate

    /// Best-effort mirror of NSCache's contents — NSCache doesn't expose
    /// count or total cost, so we maintain them ourselves under a lock.
    /// Used only for diagnostic logging; not relied on for correctness.
    private let bookkeeping = OSAllocatedUnfairLock<(count: Int, bytes: Int)>(initialState: (0, 0))

    init(name: String, countLimit: Int, byteLimit: Int) {
        self.name = name
        self.delegate = ImageCacheDelegate()
        cache.countLimit = countLimit
        cache.totalCostLimit = byteLimit
        cache.delegate = delegate
        delegate.owner = self
    }

    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func set(_ key: String, image: NSImage) {
        let w = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let h = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        let cost = w * h * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
        bookkeeping.withLock { state in
            state.count = min(state.count + 1, self.cache.countLimit)
            state.bytes = min(state.bytes + cost, self.cache.totalCostLimit)
        }
        Logger.imageCache.info(
            "\(self.name, privacy: .public) set \((key as NSString).lastPathComponent, privacy: .public) cost=\(cost / (1024 * 1024))MB approx_total=\(self.approximateBytes() / (1024 * 1024))MB count=\(self.approximateCount())"
        )
    }

    func approximateCount() -> Int { bookkeeping.withLock { $0.count } }
    func approximateBytes() -> Int { bookkeeping.withLock { $0.bytes } }

    fileprivate func noteEviction(_ image: NSImage) {
        let w = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let h = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        let cost = w * h * 4
        bookkeeping.withLock { state in
            state.count = max(0, state.count - 1)
            state.bytes = max(0, state.bytes - cost)
        }
        Logger.imageCache.info(
            "\(self.name, privacy: .public) evict cost=\(cost / (1024 * 1024))MB approx_total=\(self.approximateBytes() / (1024 * 1024))MB count=\(self.approximateCount())"
        )
    }
}

/// Per-instance NSCache delegate so each `ImageCache` knows when its own
/// cache evicts an entry and can update its bookkeeping.
private final class ImageCacheDelegate: NSObject, NSCacheDelegate {
    weak var owner: ImageCache?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let image = obj as? NSImage else { return }
        owner?.noteEviction(image)
    }
}

extension Logger {
    fileprivate static let imageCache = Logger(subsystem: "com.halfhacked.superpicky", category: "ImageCache")
}

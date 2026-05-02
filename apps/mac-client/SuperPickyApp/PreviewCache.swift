import Foundation
import ImageIO
import CoreGraphics
import CryptoKit
import os

/// On-disk JPEG cache of full-resolution decodes, keyed by a hash of the
/// photo's containing folder + the photo's basename. The whole point is to
/// turn a ~250 ms RAW decode into a ~30 ms JPEG decode on the second visit
/// to a photo, including across app launches.
///
/// Layout: `~/Library/Caches/com.halfhacked.superpicky/preview/<folder-hash>/<basename>.jpg`
enum PreviewCache {
    private static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "PreviewCache")

    /// Default cache root under `~/Library/Caches/`. Tests override
    /// `rootURLOverride` to redirect to a temp directory so they don't
    /// touch the developer's real cache.
    static var rootURL: URL { rootURLOverride ?? defaultRootURL }

    private static let defaultRootURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.halfhacked.superpicky/preview", isDirectory: true)
    }()

    /// Test-only redirect. Set in test setup, restore in teardown. Never
    /// set this from production code.
    nonisolated(unsafe) static var rootURLOverride: URL?

    /// Thread-safe runtime settings shared between the MainActor writer
    /// (`CullingConfig`) and the decode-queue reader (`ImageLoader`). Wrapping
    /// in OSAllocatedUnfairLock removes the data race that two raw
    /// `nonisolated(unsafe)` statics would have under strict concurrency.
    struct Settings: Sendable {
        var generate: Bool = true
        var capBytes: Int64 = 20 * 1024 * 1024 * 1024
    }

    private static let settingsLock = OSAllocatedUnfairLock<Settings>(initialState: Settings())

    static var settings: Settings { settingsLock.withLock { $0 } }

    static func updateSettings(_ mutate: (inout Settings) -> Void) {
        settingsLock.withLock { mutate(&$0) }
    }

    /// Maps a RAW path to its cache file URL. Same-folder photos share a
    /// hash dir so eviction and FS lookups stay localized.
    ///
    /// Cache key is folder-path + basename, validated by mtime in
    /// `freshURL`. A rename-then-reuse-same-name within the same mtime
    /// granularity could in theory return the prior photo's cache, but the
    /// mtime check covers anything that touches the source file. Folder
    /// moves orphan the old cache (acceptable — it's just disk waste).
    static func cachedURL(for rawPath: String) -> URL {
        let folder = (rawPath as NSString).deletingLastPathComponent
        let basename = ((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let hash = folderHash(folder)
        return rootURL.appendingPathComponent(hash, isDirectory: true)
                      .appendingPathComponent("\(basename).jpg")
    }

    /// Returns the cached URL only if it's fresh (mtime ≥ raw mtime).
    /// Returns nil for missing files, stale files, or unreadable mtimes.
    static func freshURL(for rawPath: String) -> URL? {
        let url = cachedURL(for: rawPath)
        guard let cachedM = mtime(url.path),
              let rawM = mtime(rawPath),
              cachedM >= rawM else {
            return nil
        }
        return url
    }

    /// Bump the cached file's mtime so LRU eviction sees it as recently used.
    /// Cheap (single utimensat); safe to call on every cache hit.
    static func touch(_ url: URL) {
        let now = Date()
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
    }

    /// Encode a CGImage to JPEG bytes. Used by `ImageLoader` to convert the
    /// in-memory decoded bitmap to a serialisable Data buffer before
    /// dispatching the disk write — that way the writer queue carries
    /// ~5 MB of bytes instead of pinning a ~96 MB decoded source.
    static func encodeJPEG(_ image: CGImage, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Atomically write a JPEG `Data` buffer to disk. Cheap relative to the
    /// encode step.
    @discardableResult
    static func writeData(_ data: Data, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            log.error("write failed at \(url.path): \(error.localizedDescription)")
            return false
        }
    }

    /// Encode and atomically write a JPEG. Caller is responsible for
    /// dispatching off the main/decode actor; this method does I/O.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, quality: Double = 0.85) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            log.error("createDirectory failed at \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
            return false
        }
        let tmp = url.appendingPathExtension("tmp")
        guard let dest = CGImageDestinationCreateWithURL(tmp as CFURL, "public.jpeg" as CFString, 1, nil) else {
            log.error("CGImageDestinationCreateWithURL failed for \(tmp.path)")
            return false
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            log.error("CGImageDestinationFinalize failed for \(tmp.path)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
            return true
        } catch {
            log.error("rename failed \(tmp.path) -> \(url.path): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: tmp)
            return false
        }
    }

    /// Total bytes used by the on-disk cache. Walks the directory; do not
    /// call from the main thread on large caches.
    static func currentSizeBytes() -> Int64 {
        var total: Int64 = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                             options: [.skipsHiddenFiles]) else {
            return 0
        }
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true, let size = v?.fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// Delete the entire cache. Returns true if the root either didn't exist
    /// or was successfully removed.
    @discardableResult
    static func clearAll() -> Bool {
        let fm = FileManager.default
        if !fm.fileExists(atPath: rootURL.path) { return true }
        do {
            try fm.removeItem(at: rootURL)
            return true
        } catch {
            log.error("clearAll failed: \(error.localizedDescription)")
            return false
        }
    }

    /// LRU eviction. Walks the cache once, sums sizes, and if over `maxBytes`,
    /// deletes oldest-mtime files until total ≤ maxBytes × 0.9. Empty hash
    /// directories are pruned.
    static func evictIfOverCap(maxBytes: Int64) {
        guard maxBytes > 0 else { return }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return
        }
        struct Entry { let url: URL; let size: Int64; let mtime: Date }
        var entries: [Entry] = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard v?.isRegularFile == true, let size = v?.fileSize, let m = v?.contentModificationDate else {
                continue
            }
            entries.append(Entry(url: url, size: Int64(size), mtime: m))
            total += Int64(size)
        }
        guard total > maxBytes else { return }

        let target = Int64(Double(maxBytes) * 0.9)
        let oldestFirst = entries.sorted { $0.mtime < $1.mtime }
        var freed: Int64 = 0
        let need = total - target
        var evicted = 0
        for e in oldestFirst {
            if freed >= need { break }
            do {
                try fm.removeItem(at: e.url)
                freed += e.size
                evicted += 1
            } catch {
                log.error("evict failed for \(e.url.path): \(error.localizedDescription)")
            }
        }
        pruneEmptyHashDirs()
        log.info("evicted \(evicted) files, freed \(freed) bytes (\(total) -> \(total - freed))")
    }

    // MARK: - Internal helpers

    private static func pruneEmptyHashDirs() {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: rootURL,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles]) else {
            return
        }
        for dir in kids where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let inside = try? fm.contentsOfDirectory(atPath: dir.path), inside.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }
    }

    private static func mtime(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return attrs[.modificationDate] as? Date
    }

    /// SHA-256 of the absolute folder path, truncated to 16 hex chars.
    /// 64 bits of namespace is plenty to avoid collisions across folders.
    private static func folderHash(_ folderPath: String) -> String {
        let data = Data(folderPath.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }
}

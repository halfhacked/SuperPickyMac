import Testing
import Foundation
@testable import SuperPicky

/// Pure-function tests for `ImageCacheBudget.compute(physicalMemory:aggressive:)`.
/// The function picks the in-RAM `ImageCache.fullRes` budget from the host
/// machine's physical memory and the user's "aggressive cache" preference,
/// then clamps the result into `[minBytes, maxBytes]`.
struct ImageCacheBudgetTests {

    private let oneGB: UInt64 = 1024 * 1024 * 1024

    @Test func floorOnLowMemoryMac() {
        // 8 GB Mac, balanced: 25% would be 2 GB, but minBytes (800 MB) is
        // the floor — except 2 GB > 800 MB so balance wins. The actual
        // floor case is 1 GB physical; 25% = 256 MB, clamped to 800 MB.
        let (count, bytes) = ImageCacheBudget.compute(physicalMemory: oneGB, aggressive: false)
        #expect(bytes == ImageCacheBudget.minBytes)
        #expect(count >= 8)
    }

    @Test func balancedScalesWith25Percent() {
        let (count, bytes) = ImageCacheBudget.compute(physicalMemory: 64 * oneGB, aggressive: false)
        // 25% of 64 GB = 16 GB, well within [minBytes, maxBytes].
        #expect(bytes == 16 * Int(oneGB))
        #expect(count == bytes / ImageCacheBudget.estimatedEntryBytes)
    }

    @Test func aggressiveDoublesBudget() {
        let (_, bytes) = ImageCacheBudget.compute(physicalMemory: 64 * oneGB, aggressive: true)
        // 50% of 64 GB = 32 GB — exactly maxBytes.
        #expect(bytes == ImageCacheBudget.maxBytes)
    }

    @Test func ceilingClampsHugeMemory() {
        let (_, bytes) = ImageCacheBudget.compute(physicalMemory: 256 * oneGB, aggressive: true)
        // 50% of 256 GB = 128 GB, clamped to maxBytes (32 GB).
        #expect(bytes == ImageCacheBudget.maxBytes)
    }

    @Test func countNeverBelowEight() {
        // Synthetic tiny memory: bytes clamps to minBytes (800 MB), and
        // 800 MB / 96 MB = 8 entries, which is also the floor. Use a
        // value so small that the raw computation would yield 0 entries.
        let (count, bytes) = ImageCacheBudget.compute(physicalMemory: 0, aggressive: false)
        #expect(bytes == ImageCacheBudget.minBytes)
        #expect(count == 8)
    }
}

import Testing
import Foundation
@testable import SuperPicky

/// Pure-function tests for `ImageCacheBudget.compute(physicalMemory:aggressive:)`.
/// The function picks the in-RAM `ImageCache.fullRes` budget from the host
/// machine's physical memory and the user's "aggressive cache" preference,
/// then clamps the result into `[minBytes, maxBytes]`.
struct ImageCacheBudgetTests {

    private let oneGB: UInt64 = 1024 * 1024 * 1024

    /// 1 GB physical → 25% = 256 MB, clamped up to the 800 MB floor.
    @Test func balancedClampsUpToFloor() {
        let (count, bytes) = ImageCacheBudget.compute(physicalMemory: oneGB, aggressive: false)
        #expect(bytes == ImageCacheBudget.minBytes)
        #expect(count == 8)
    }

    /// 64 GB balanced → 25% = 16 GB, well within [minBytes, maxBytes].
    @Test func balancedScalesAt25Percent() {
        let (_, bytes) = ImageCacheBudget.compute(physicalMemory: 64 * oneGB, aggressive: false)
        #expect(bytes == 16 * Int(oneGB))
    }

    /// 16 GB aggressive → 50% = 8 GB, well within [minBytes, maxBytes].
    /// Pins the aggressive multiplier in the unclamped regime.
    @Test func aggressiveScalesAt50Percent() {
        let (_, bytes) = ImageCacheBudget.compute(physicalMemory: 16 * oneGB, aggressive: true)
        #expect(bytes == 8 * Int(oneGB))
    }

    /// Same physical memory, balanced vs aggressive: aggressive must double
    /// the byte budget when neither result is clamped.
    @Test func aggressiveDoublesBalanced() {
        let balanced = ImageCacheBudget.compute(physicalMemory: 16 * oneGB, aggressive: false)
        let aggressive = ImageCacheBudget.compute(physicalMemory: 16 * oneGB, aggressive: true)
        #expect(aggressive.bytes == balanced.bytes * 2)
    }

    /// 256 GB aggressive → 50% = 128 GB, clamped down to maxBytes (32 GB).
    @Test func aggressiveClampsDownToCeiling() {
        let (_, bytes) = ImageCacheBudget.compute(physicalMemory: 256 * oneGB, aggressive: true)
        #expect(bytes == ImageCacheBudget.maxBytes)
    }
}

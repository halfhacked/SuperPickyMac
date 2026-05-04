import Testing
import Foundation
@testable import SuperPicky

// MARK: - Pure target/streak math

/// Tests for `PrefetchCoordinator.computeTargets` — the pure derivation of
/// the next prefetch target list from the current selection, the previous
/// selection, and the running streak counter.
@Suite struct PrefetchTargetsTests {

    // MARK: Fixture builders

    private func plainPhotos(_ count: Int) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "p\(i).ARW", filePath: "/tmp/p\(i).ARW", folderPath: "/tmp")
        }
    }

    private func photosWithBurst(burstAt range: Range<Int>, total: Int) -> [Photo] {
        let burstID = UUID()
        return (0..<total).map { i in
            var p = Photo(filename: "p\(i).ARW", filePath: "/tmp/p\(i).ARW", folderPath: "/tmp")
            if range.contains(i) { p.burstGroupID = burstID }
            return p
        }
    }

    // MARK: Streak math

    @Test func firstCallNoStreakDefaultsForward() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 5, photos: plainPhotos(20), lastIndex: nil, streak: 0
        )
        #expect(result.step == 1)
        #expect(result.newStreak == 0)  // no movement to score yet
    }

    @Test func forwardThenForwardExtendsStreak() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 6, photos: plainPhotos(20), lastIndex: 5, streak: 1
        )
        #expect(result.step == 1)
        #expect(result.newStreak == 2)
    }

    @Test func reversalResetsStreak() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 9, photos: plainPhotos(20), lastIndex: 10, streak: 5
        )
        #expect(result.step == -1)
        #expect(result.newStreak == -1)
    }

    @Test func sameIndexKeepsDirection() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 5, photos: plainPhotos(20), lastIndex: 5, streak: 3
        )
        #expect(result.step == 1)
        #expect(result.newStreak == 3)
    }

    @Test func sameIndexFromBackwardStreakKeepsBackward() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 5, photos: plainPhotos(20), lastIndex: 5, streak: -3
        )
        #expect(result.step == -1)
        #expect(result.newStreak == -3)
    }

    // MARK: Burst-aware ordering

    @Test func sameBurstFirstNextBurstAfter() {
        // Burst at indices 2..4. Plain photos at 0,1,5,6,7,...
        // From index 3 with step +1, expect burst-mate 4 first (offset
        // ahead in step direction), then 2 (behind), then non-burst
        // photos starting at index 5.
        let photos = photosWithBurst(burstAt: 2..<5, total: 10)
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 3, photos: photos, lastIndex: nil, streak: 0
        )
        let firstThree = Array(result.targets.prefix(3))
        #expect(firstThree[0] == "/tmp/p4.ARW", "burst-mate ahead first")
        #expect(firstThree[1] == "/tmp/p2.ARW", "burst-mate behind second")
        #expect(firstThree[2] == "/tmp/p5.ARW", "next-burst photo third")
    }

    // MARK: Depth boost

    @Test func nextBurstDepthRespectsBoost() {
        // streak == +5 → boost = (5-1)*2 = 8 → depth = 6 + 8 = 14, capped
        // at maxNextBurstDepth (30). With a 30-photo plain folder starting
        // from index 5 forward, depth ≤ 14 photos collected.
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 5, photos: plainPhotos(30), lastIndex: 4, streak: 5
        )
        // After streak updates to 6, boost = 10, depth = 16. Forward from
        // index 5 in a 30-photo folder, at most 16 photos collected.
        #expect(result.targets.count <= 16)
        #expect(result.targets.count >= 6, "baseline depth must always fire")
    }

    // MARK: Caps

    @Test func targetsCappedAtMaxTargets() {
        // Force very long depth boost via streak in a long folder; targets
        // capped at PrefetchCoordinator.maxTargets (40).
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 0, photos: plainPhotos(200), lastIndex: -1, streak: 200
        )
        #expect(result.targets.count <= 40)
    }

    // MARK: Edge cases

    @Test func singlePhotoFolder() {
        let result = PrefetchCoordinator.computeTargets(
            currentIndex: 0, photos: plainPhotos(1), lastIndex: nil, streak: 0
        )
        #expect(result.targets.isEmpty)
    }

    @Test func outOfRangeIndexReturnsEmpty() {
        let above = PrefetchCoordinator.computeTargets(
            currentIndex: 999, photos: plainPhotos(5), lastIndex: nil, streak: 0
        )
        #expect(above.targets.isEmpty)
        #expect(above.newStreak == 0)
        let below = PrefetchCoordinator.computeTargets(
            currentIndex: -1, photos: plainPhotos(5), lastIndex: nil, streak: 0
        )
        #expect(below.targets.isEmpty)
        #expect(below.newStreak == 0)
    }
}

// MARK: - Orchestration via fake sink

/// Records every `has`/`warm` invocation so we can assert on the
/// orchestration without touching `ImageLoader` or `ImageCache`.
@MainActor
final class RecorderSink: PrefetchSink {
    var present: Set<String> = []
    var warmed: [String] = []
    var cancelled: [String] = []

    func has(_ path: String) -> Bool { present.contains(path) }

    func warm(_ path: String) -> Task<Void, Never> {
        warmed.append(path)
        let p = path
        return Task { [weak self] in
            // Yield once so the task can observe cancellation if the
            // coordinator decides to drop us before we complete.
            await Task.yield()
            if Task.isCancelled { self?.cancelled.append(p) }
        }
    }
}

@Suite @MainActor struct PrefetchOrchestrationTests {

    private func plainPhotos(_ count: Int) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "p\(i).ARW", filePath: "/tmp/p\(i).ARW", folderPath: "/tmp")
        }
    }

    @Test func firstUpdateSchedulesAllTargets() async {
        let recorder = RecorderSink()
        let coord = PrefetchCoordinator(sink: recorder)
        coord.update(currentIndex: 5, photos: plainPhotos(30))

        let expected = PrefetchCoordinator.computeTargets(
            currentIndex: 5, photos: plainPhotos(30), lastIndex: nil, streak: 0
        )
        #expect(recorder.warmed == expected.targets)
    }

    @Test func inflightSurvivesAdjacentMove() async {
        let recorder = RecorderSink()
        let coord = PrefetchCoordinator(sink: recorder)
        coord.update(currentIndex: 5, photos: plainPhotos(50))
        let firstWarmCount = recorder.warmed.count
        coord.update(currentIndex: 6, photos: plainPhotos(50))
        // Paths still in the new target set must NOT have been re-warmed
        // — the diff filters them out.
        let duplicates = recorder.warmed.reduce(into: [String: Int]()) { d, p in
            d[p, default: 0] += 1
        }
        let anyDup = duplicates.values.contains { $0 > 1 }
        #expect(!anyDup, "no path should be warmed twice across adjacent updates")
        #expect(recorder.warmed.count > firstWarmCount, "some new targets must have appeared")
    }

    @Test func outOfSetIsCancelled() async {
        let recorder = RecorderSink()
        let coord = PrefetchCoordinator(sink: recorder)
        coord.update(currentIndex: 5, photos: plainPhotos(200))
        coord.update(currentIndex: 180, photos: plainPhotos(200))
        // Let the cancelled tasks observe their cancellation.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!recorder.cancelled.isEmpty,
                "tasks dropped from the new target set must be cancelled")
    }

    @Test func cachedPathSkipped() async {
        let recorder = RecorderSink()
        recorder.present = ["/tmp/p10.ARW"]
        let coord = PrefetchCoordinator(sink: recorder)
        coord.update(currentIndex: 5, photos: plainPhotos(30))
        #expect(!recorder.warmed.contains("/tmp/p10.ARW"))
    }

    @Test func resetCancelsEverything() async {
        let recorder = RecorderSink()
        let coord = PrefetchCoordinator(sink: recorder)
        coord.update(currentIndex: 5, photos: plainPhotos(30))
        coord.reset()
        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(recorder.cancelled.count == recorder.warmed.count,
                "reset must cancel every in-flight task")
    }

    @Test func prefillResetsStreak() async {
        // Coordinator A: fresh, just one update at idx 30.
        let recA = RecorderSink()
        let coordA = PrefetchCoordinator(sink: recA)
        coordA.update(currentIndex: 30, photos: plainPhotos(60))
        let baseline = Set(recA.warmed)

        // Coordinator B: build a long forward streak (which inflates the
        // depth boost so update()s schedule extra targets), then reset +
        // prefill at 30 — matching production's reset-then-prefill in
        // AppState. After prefill, the new targets must match A's baseline
        // — if the streak weren't reset, B would carry a deeper, boosted
        // target list rather than the baseline depth.
        let recB = RecorderSink()
        let coordB = PrefetchCoordinator(sink: recB)
        let photos = plainPhotos(60)
        for i in 0..<10 {
            coordB.update(currentIndex: i, photos: photos)
        }
        coordB.reset()  // mirrors AppState.swift:204
        let beforePrefill = recB.warmed.count
        coordB.prefill(photos: photos, around: 30)
        let prefillTargets = Set(recB.warmed.suffix(from: beforePrefill))

        #expect(prefillTargets == baseline,
                "prefill must produce the same targets as a fresh coordinator")
    }
}

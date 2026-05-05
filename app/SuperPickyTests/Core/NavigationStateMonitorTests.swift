import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized)
@MainActor
struct NavigationStateMonitorTests {

    /// Mutable clock for deterministic timing.
    final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ initial: Date = Date(timeIntervalSinceReferenceDate: 0)) { self.now = initial }
        func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
    }

    private func makeMonitor(_ clock: TestClock) -> NavigationStateMonitor {
        NavigationStateMonitor(clock: { clock.now })
    }

    private func dummyPhotos(_ count: Int) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "p\(i).ARW",
                  filePath: "/tmp/p\(i).ARW",
                  folderPath: "/tmp")
        }
    }

    @Test func idleStartsIdle() {
        let monitor = makeMonitor(TestClock())
        #expect(monitor.state == .idle)
    }

    @Test func singlePressEntersActive() {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        monitor.note(currentIndex: 0, photos: dummyPhotos(3))
        #expect(monitor.state == .active)
    }

    @Test func twoFastPressesEnterSkim() {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        monitor.note(currentIndex: 0, photos: dummyPhotos(3))
        clock.advance(0.1)  // 100 ms — well under 250 ms threshold
        monitor.note(currentIndex: 1, photos: dummyPhotos(3))
        #expect(monitor.state == .skim)
    }

    @Test func slowPressesStayActive() {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        monitor.note(currentIndex: 0, photos: dummyPhotos(3))
        clock.advance(0.4)  // 400 ms — over 250 ms threshold
        monitor.note(currentIndex: 1, photos: dummyPhotos(3))
        #expect(monitor.state == .active)
    }

    @Test func resetReturnsToIdle() {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        monitor.note(currentIndex: 0, photos: dummyPhotos(3))
        monitor.reset()
        #expect(monitor.state == .idle)
    }

    @Test func dwellFiresAfterIdleThreshold() async throws {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        let photos = dummyPhotos(3)

        var dwellCalls: [(Int, Int)] = []  // (index, photos.count)
        monitor.onEnterDwell = { idx, photos in
            dwellCalls.append((idx, photos.count))
        }

        monitor.note(currentIndex: 1, photos: photos)
        // Wait long enough for the real-time dwell timer to fire.
        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(monitor.state == .dwell)
        #expect(dwellCalls.count == 1)
        #expect(dwellCalls.first?.0 == 1)
        #expect(dwellCalls.first?.1 == 3)
    }

    @Test func dwellTimerCancelsOnNewPress() async throws {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        let photos = dummyPhotos(3)

        var dwellCalls = 0
        monitor.onEnterDwell = { _, _ in dwellCalls += 1 }

        monitor.note(currentIndex: 0, photos: photos)
        try await Task.sleep(nanoseconds: 150_000_000)  // safely below dwell threshold

        clock.advance(0.3)
        monitor.note(currentIndex: 1, photos: photos)  // resets timer
        try await Task.sleep(nanoseconds: 500_000_000)

        // Only one dwell fires (the second one), not two.
        #expect(dwellCalls == 1)
    }

    @Test func dwellUsesLatestContext() async throws {
        let clock = TestClock()
        let monitor = makeMonitor(clock)

        var dwellIdx: Int = -1
        monitor.onEnterDwell = { idx, _ in dwellIdx = idx }

        monitor.note(currentIndex: 5, photos: dummyPhotos(10))
        clock.advance(0.1)
        monitor.note(currentIndex: 6, photos: dummyPhotos(10))
        clock.advance(0.1)
        monitor.note(currentIndex: 7, photos: dummyPhotos(10))
        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(dwellIdx == 7)
    }

    @Test func resetCancelsPendingDwell() async throws {
        let clock = TestClock()
        let monitor = makeMonitor(clock)
        var dwellCalls = 0
        monitor.onEnterDwell = { _, _ in dwellCalls += 1 }

        monitor.note(currentIndex: 0, photos: dummyPhotos(3))
        monitor.reset()
        try await Task.sleep(nanoseconds: 700_000_000)

        #expect(monitor.state == .idle)
        #expect(dwellCalls == 0)
    }
}

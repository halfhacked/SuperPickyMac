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
}

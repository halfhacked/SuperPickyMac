import Foundation
import os

/// Classifies the user's photo-selection input timing into one of four
/// states. `PreviewView` reads `state` to choose between the fast preview
/// decode path (during skim) and the full-resolution path (otherwise).
/// `PrefetchCoordinator` installs an `onEnterDwell` hook to fire its
/// update only after the user has paused.
@MainActor
@Observable
final class NavigationStateMonitor {
    static let shared = NavigationStateMonitor()
    static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "NavigationState")

    enum State: Sendable, Equatable { case idle, active, skim, dwell }

    /// Inter-keypress gap below which we promote ACTIVE to SKIM.
    static let skimThreshold: TimeInterval = 0.25
    /// Silence after the last keypress that triggers DWELL.
    static let dwellThreshold: TimeInterval = 0.3

    private(set) var state: State = .idle

    /// Hook invoked once the dwell timer expires. Receives the latest
    /// `(currentIndex, photos)` captured by `note(...)`.
    var onEnterDwell: ((Int, [Photo]) -> Void)?

    private var lastKeypressAt: Date?
    private var pendingContext: (currentIndex: Int, photos: [Photo])?
    private var dwellTimer: Task<Void, Never>?
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) {
        self.clock = clock
    }

    /// Record a selection change. Updates state and captures the context
    /// for the eventual dwell hook.
    func note(currentIndex: Int, photos: [Photo]) {
        let now = clock()
        let gap = lastKeypressAt.map { now.timeIntervalSince($0) }
        lastKeypressAt = now
        pendingContext = (currentIndex, photos)
        let newState: State = (gap.map { $0 < Self.skimThreshold } ?? false) ? .skim : .active
        state = newState
        Self.log.debug("note idx=\(currentIndex) gap=\(gap ?? -1, privacy: .public) state=\(String(describing: newState), privacy: .public)")
        scheduleDwellTimer()
    }

    /// Cancel pending state, clear context, return to `.idle`. Called on
    /// folder change.
    func reset() {
        dwellTimer?.cancel()
        dwellTimer = nil
        lastKeypressAt = nil
        pendingContext = nil
        state = .idle
    }

    private func scheduleDwellTimer() {
        dwellTimer?.cancel()
        let delayNs = UInt64(Self.dwellThreshold * 1_000_000_000)
        dwellTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled else { return }
            self?.enterDwell()
        }
    }

    private func enterDwell() {
        state = .dwell
        Self.log.info("enter dwell")
        if let ctx = pendingContext {
            onEnterDwell?(ctx.currentIndex, ctx.photos)
        }
    }
}

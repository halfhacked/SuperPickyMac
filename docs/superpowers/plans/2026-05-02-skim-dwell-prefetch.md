# Skim/Dwell Adaptive Prefetch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a skim/dwell state monitor so prefetch fires only on dwell, and zoom-mode foreground decode drops to a fast 2000 px preview path during fast scrubbing — making fast skim hit ~30/sec instead of the current ~4/sec ARW-decode ceiling.

**Architecture:** A new `@Observable @MainActor` class `NavigationStateMonitor` classifies user input into `idle / active / skim / dwell` states based on inter-keypress timing (250 ms skim threshold, 500 ms dwell threshold). `PreviewView` reads the state and branches its decode path (zoom + skim → 2000 px preview, otherwise current behavior). `PrefetchCoordinator.update` no longer fires per-selection-change; it's installed as the `onEnterDwell` callback on the monitor, so prefetch runs once after each dwell.

**Tech Stack:** Swift, SwiftUI, `@Observable`, `Task`-based timers, Swift Testing for L1, XCUITest for L3.

**Spec:** `docs/superpowers/specs/2026-05-02-skim-dwell-prefetch-design.md`

---

## File Structure

| Path | Status | Responsibility |
|---|---|---|
| `apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift` | new | State machine: classify keypresses into idle/active/skim/dwell, fire `onEnterDwell` after 500 ms idle. ~120 lines. |
| `apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift` | new | L1 unit tests for the state machine. ~150 lines. |
| `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift` | edit | Install `onEnterDwell` hook in `static let shared` initializer; remove the requirement that callers fire `update` per-selection-change (it now happens via the hook). |
| `apps/mac-client/SuperPickyApp/PreviewView.swift` | edit | Read `NavigationStateMonitor.shared.state` at task start; in zoom mode, take the 2000 px preview path during skim instead of full-res. Observe state transitions; on dwell, upgrade in place to full-res when displaying preview-tier in zoom. |
| `apps/mac-client/SuperPickyApp/ContentView.swift` | edit | Replace direct `PrefetchCoordinator.shared.update(...)` call with `NavigationStateMonitor.shared.note(...)`. |
| `apps/mac-client/SuperPickyApp/AppState.swift` | edit | Call `NavigationStateMonitor.shared.reset()` on folder switch alongside the existing `PrefetchCoordinator.shared.reset()`. |
| `apps/mac-client/SuperPickyUITests/PreviewCacheUITests.swift` | edit | Add `test03_skimSuppressesPrefetchUntilDwell`. |
| `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj` | edit | Register `NavigationStateMonitor.swift` and `NavigationStateMonitorTests.swift`. |

---

## Task 1: NavigationStateMonitor — skeleton + state-classification (TDD)

**Files:**
- Create: `apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift`
- Create: `apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift`

- [ ] **Step 1: Write the failing test for the state classification**

Create `apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test and verify it fails**

Run from `apps/mac-client/`:

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/NavigationStateMonitorTests 2>&1 | tail -10
```

Expected: BUILD FAILED — `cannot find 'NavigationStateMonitor' in scope`.

- [ ] **Step 3: Implement the minimal class**

Create `apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift`:

```swift
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
    static let dwellThreshold: TimeInterval = 0.5

    private(set) var state: State = .idle

    private var lastKeypressAt: Date?
    private var pendingContext: (currentIndex: Int, photos: [Photo])?
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
        state = (gap.map { $0 < Self.skimThreshold } ?? false) ? .skim : .active
    }

    /// Cancel pending state, clear context, return to `.idle`. Called on
    /// folder change.
    func reset() {
        lastKeypressAt = nil
        pendingContext = nil
        state = .idle
    }
}
```

- [ ] **Step 4: Register the new files in pbxproj**

Find an existing Core test entry (e.g. `AssignedSpeciesTests.swift`) and add three sibling entries: a `PBXBuildFile` and `PBXFileReference` and entries in the `Core` group's children list and the `SuperPickyTests` Sources build phase. Same drill for `NavigationStateMonitor.swift` in the app target.

Use these stable IDs (match the existing project's hex-id pattern):

```
NavigationStateMonitor.swift:
  Build:    C0FE12CD3456789012345678
  FileRef:  D0FE12CD3456789012345678

NavigationStateMonitorTests.swift:
  Build:    C1FE12CD3456789012345678
  FileRef:  D1FE12CD3456789012345678
```

- [ ] **Step 5: Run the test and verify it passes**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/NavigationStateMonitorTests 2>&1 | grep -E "Test |passed|failed" | tail -10
```

Expected: all 5 tests pass.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift \
        apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(nav): NavigationStateMonitor — skim/dwell state machine"
```

---

## Task 2: NavigationStateMonitor — dwell timer + onEnterDwell hook

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift`
- Modify: `apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `NavigationStateMonitorTests.swift`:

```swift
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
        try await Task.sleep(nanoseconds: 300_000_000)  // before dwell threshold

        clock.advance(0.3)
        monitor.note(currentIndex: 1, photos: photos)  // resets timer
        try await Task.sleep(nanoseconds: 700_000_000)

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
```

- [ ] **Step 2: Run the tests and verify they fail**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/NavigationStateMonitorTests 2>&1 | grep -E "passed|failed" | tail -10
```

Expected: 4 new tests fail (timer not implemented).

- [ ] **Step 3: Add the dwell timer to NavigationStateMonitor.swift**

Replace the body of `NavigationStateMonitor` with:

```swift
@MainActor
@Observable
final class NavigationStateMonitor {
    static let shared = NavigationStateMonitor()
    static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "NavigationState")

    enum State: Sendable, Equatable { case idle, active, skim, dwell }

    static let skimThreshold: TimeInterval = 0.25
    static let dwellThreshold: TimeInterval = 0.5

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
```

- [ ] **Step 4: Run the tests and verify they pass**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/NavigationStateMonitorTests 2>&1 | grep -E "Test run with|passed|failed" | tail -5
```

Expected: 9 tests pass total.

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift \
        apps/mac-client/SuperPickyTests/Core/NavigationStateMonitorTests.swift
git commit -m "feat(nav): dwell timer + onEnterDwell hook"
```

---

## Task 3: Wire ContentView through NavigationStateMonitor

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ContentView.swift`

- [ ] **Step 1: Find the existing PrefetchCoordinator call site**

```bash
grep -n "PrefetchCoordinator" apps/mac-client/SuperPickyApp/ContentView.swift
```

Expected output: one match in an `.onChange(of: selectedPhotoID)` block.

- [ ] **Step 2: Replace the direct prefetch call with `note(...)`**

In `apps/mac-client/SuperPickyApp/ContentView.swift`, find:

```swift
                    .onChange(of: selectedPhotoID) { _, newID in
                        guard let newID,
                              let idx = filteredPhotos.firstIndex(where: { $0.id == newID }) else {
                            return
                        }
                        PrefetchCoordinator.shared.update(
                            currentIndex: idx,
                            photos: filteredPhotos
                        )
                    }
```

Replace with:

```swift
                    .onChange(of: selectedPhotoID) { _, newID in
                        guard let newID,
                              let idx = filteredPhotos.firstIndex(where: { $0.id == newID }) else {
                            return
                        }
                        NavigationStateMonitor.shared.note(
                            currentIndex: idx,
                            photos: filteredPhotos
                        )
                    }
```

- [ ] **Step 3: Build to confirm it compiles**

```bash
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | grep -v AppIcon | tail -5
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ContentView.swift
git commit -m "refactor(nav): ContentView routes selection changes through NavigationStateMonitor"
```

---

## Task 4: Install onEnterDwell hook in PrefetchCoordinator

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift`

- [ ] **Step 1: Locate the existing `static let shared`**

```bash
grep -n "static let shared" apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift
```

Expected: one match like `static let shared = PrefetchCoordinator()`.

- [ ] **Step 2: Replace with a closure-initialized singleton that installs the hook**

In `PrefetchCoordinator.swift`, find:

```swift
    static let shared = PrefetchCoordinator()
```

Replace with:

```swift
    static let shared: PrefetchCoordinator = {
        let coordinator = PrefetchCoordinator()
        // Prefetch fires on dwell. ContentView's selection-change
        // callback now routes through NavigationStateMonitor; the
        // monitor's dwell timer invokes update() with the latest
        // captured (currentIndex, photos).
        NavigationStateMonitor.shared.onEnterDwell = { [weak coordinator] index, photos in
            coordinator?.update(currentIndex: index, photos: photos)
        }
        return coordinator
    }()
```

- [ ] **Step 3: Build and run all L1 tests**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests 2>&1 | grep -E "Test run with|TEST SUC|TEST FAIL" | tail -3
```

Expected: TEST SUCCEEDED, all tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift
git commit -m "feat(nav): PrefetchCoordinator fires update() via NavigationStateMonitor.onEnterDwell"
```

---

## Task 5: AppState resets NavigationStateMonitor on folder switch

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift`

- [ ] **Step 1: Find the existing prefetch reset**

```bash
grep -n "PrefetchCoordinator.shared.reset" apps/mac-client/SuperPickyApp/AppState.swift
```

Expected: one match inside the `if isFolderSwitch` block in `loadPhotos`.

- [ ] **Step 2: Add the monitor reset alongside it**

In `AppState.swift`, find:

```swift
            if isFolderSwitch {
                let paths = allPhotos.map(\.filePath)
                let prefillPhotos = allPhotos
                Task { @MainActor in
                    PreviewSweepCoordinator.shared.start(folder: folder, paths: paths)
                    PrefetchCoordinator.shared.reset()
                    // Start filling the in-RAM working set right after the
                    // folder loads, before the user navigates. Centred on
                    // photo 0 (the auto-selected one).
                    if !prefillPhotos.isEmpty {
                        PrefetchCoordinator.shared.prefill(photos: prefillPhotos, around: 0)
                    }
                }
            }
```

Insert `NavigationStateMonitor.shared.reset()` right after the `PrefetchCoordinator.shared.reset()` line:

```swift
            if isFolderSwitch {
                let paths = allPhotos.map(\.filePath)
                let prefillPhotos = allPhotos
                Task { @MainActor in
                    PreviewSweepCoordinator.shared.start(folder: folder, paths: paths)
                    PrefetchCoordinator.shared.reset()
                    NavigationStateMonitor.shared.reset()
                    if !prefillPhotos.isEmpty {
                        PrefetchCoordinator.shared.prefill(photos: prefillPhotos, around: 0)
                    }
                }
            }
```

- [ ] **Step 3: Build to confirm**

```bash
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | grep -v AppIcon | tail -3
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift
git commit -m "fix(nav): reset NavigationStateMonitor on folder switch"
```

---

## Task 6: PreviewView — branch decode path on skim state in zoom mode

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PreviewView.swift`

This task changes only the decode-path branching at task start. The dwell-upgrade observer comes in Task 7.

- [ ] **Step 1: Read the existing `.task(id: filePath)` block**

```bash
grep -n ".task(id: filePath)" apps/mac-client/SuperPickyApp/PreviewView.swift
```

Identify the existing structure: zoom > 1.0 → `loadFullRes`, otherwise 2000 px preview path.

- [ ] **Step 2: Modify the task body to consult the state monitor**

In `PreviewView.swift`, find the `.task(id: filePath)` block (currently around line 86). Replace its first branch:

```swift
        .task(id: filePath) {
            isFullRes = false
            if zoomState.scale > 1.0 {
                if let full = await loadFullRes(filePath) {
                    guard !Task.isCancelled else { return }
                    image = full
                    isFullRes = true
                }
                return
            }
```

with:

```swift
        .task(id: filePath) {
            isFullRes = false
            // Zoom + skim: take the 2000 px preview path so fast scrubbing
            // hits ~30/sec. Single deliberate keypresses in zoom (state !=
            // .skim at task start) keep the current direct-to-full-res
            // behavior.
            let inSkim = NavigationStateMonitor.shared.state == .skim
            if zoomState.scale > 1.0, !inSkim {
                if let full = await loadFullRes(filePath) {
                    guard !Task.isCancelled else { return }
                    image = full
                    isFullRes = true
                }
                return
            }
```

The fit-mode branch (the rest of the task body) is unchanged. Note: zoom + skim now falls through into the fit-mode 2000 px preview path, which is exactly what we want.

- [ ] **Step 3: Build and run L1 tests**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests 2>&1 | grep -E "Test run with|TEST SUC|TEST FAIL" | tail -3
```

Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PreviewView.swift
git commit -m "feat(preview): use 2000 px preview path in zoom mode during skim"
```

---

## Task 7: PreviewView — upgrade in place when state becomes dwell

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PreviewView.swift`

After Task 6 we drop to 2000 px preview during zoom + skim. Now we need to upgrade to full-res once the user dwells.

- [ ] **Step 1: Locate the existing zoom-onChange upgrade**

```bash
grep -n "onChange(of: zoomState.scale)" apps/mac-client/SuperPickyApp/PreviewView.swift
```

The block we already have looks like:

```swift
        .onChange(of: zoomState.scale) { _, newScale in
            guard newScale > 1.0, !isFullRes else { return }
            isFullRes = true
            if let cached = ImageCache.fullRes.get(filePath) {
                image = cached
                return
            }
            let pinnedPath = filePath
            Task {
                if let full = await loadFullRes(pinnedPath) {
                    guard !Task.isCancelled, filePath == pinnedPath else { return }
                    image = full
                } else if filePath == pinnedPath {
                    isFullRes = false
                }
            }
        }
```

We'll factor its body out so the new state-onChange handler can share it.

- [ ] **Step 2: Extract the upgrade as a method**

Add a private method on `AsyncPreviewImage` (right above the `body`):

```swift
    /// Replace the displayed preview-tier image with a full-res decode in
    /// place. Used both when the user zooms in and when the user dwells
    /// on a photo while already at zoom > 1.0.
    private func upgradeToFullRes() {
        if isFullRes { return }
        isFullRes = true
        if let cached = ImageCache.fullRes.get(filePath) {
            image = cached
            return
        }
        let pinnedPath = filePath
        Task {
            if let full = await loadFullRes(pinnedPath) {
                guard !Task.isCancelled, filePath == pinnedPath else { return }
                image = full
            } else if filePath == pinnedPath {
                isFullRes = false
            }
        }
    }
```

Replace the existing `.onChange(of: zoomState.scale)` body with:

```swift
        .onChange(of: zoomState.scale) { _, newScale in
            guard newScale > 1.0 else { return }
            upgradeToFullRes()
        }
```

- [ ] **Step 3: Add the state-change observer**

Right after the `.onChange(of: zoomState.scale)` block, add:

```swift
        .onChange(of: NavigationStateMonitor.shared.state) { _, newState in
            // After a skim ends in zoom mode, swap the soft preview-tier
            // image we displayed during skim for a full-res decode.
            guard newState == .dwell, zoomState.scale > 1.0 else { return }
            upgradeToFullRes()
        }
```

- [ ] **Step 4: Build and run L1 tests**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests 2>&1 | grep -E "Test run with|TEST SUC|TEST FAIL" | tail -3
```

Expected: TEST SUCCEEDED.

- [ ] **Step 5: Manual verification (Release build)**

```bash
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' -configuration Release 2>&1 | grep -E "BUILD" | tail -3
pkill -9 -f "SuperPicky.app/Contents/MacOS/SuperPicky" 2>/dev/null; sleep 1
open ~/Library/Developer/Xcode/DerivedData/SuperPicky-*/Build/Products/Release/SuperPicky.app
```

In the running app:
1. Open a folder of ARWs.
2. Press `z` to enter zoom (actual-pixels).
3. Hold `→` for ~5 s. Photos should cycle visibly faster than ~4/sec; each frame slightly soft.
4. Release. Within ~250 ms the current photo sharpens to full-res.
5. Check `log stream --predicate 'category == "NavigationState"'` shows `enter dwell` after ~500 ms idle.

If the upgrade-on-dwell isn't firing, check whether `.onChange(of: NavigationStateMonitor.shared.state)` actually re-evaluates — `@Observable` should make this work, but if SwiftUI doesn't see the read, change the call site to `@State private var navState = NavigationStateMonitor.shared` and reference `navState.state` instead.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PreviewView.swift
git commit -m "feat(preview): upgrade in place to full-res when state becomes dwell"
```

---

## Task 8: L3 XCUITest — skim suppresses prefetch until dwell

**Files:**
- Modify: `apps/mac-client/SuperPickyUITests/PreviewCacheUITests.swift`

- [ ] **Step 1: Add the new test**

In `apps/mac-client/SuperPickyUITests/PreviewCacheUITests.swift`, add a new method after `test02_clearedCacheRegenerates`:

```swift
    func test03_skimSuppressesPrefetchUntilDwell() throws {
        // Wipe cache — the disk-JPG sweep is gated behind dwell too via
        // the foreground decode path, so a fresh start makes the delta
        // visible.
        try? FileManager.default.removeItem(at: Self.cacheRoot)

        let app = Self.app!
        XCTAssertTrue(app.images[A11y.photoPreview].waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])

        // Rapid keypresses — XCUITest delivers them synchronously, so the
        // inter-key gap is ~0–10 ms, well under the 250 ms skim threshold.
        for _ in 0..<10 {
            app.typeKey(.rightArrow, modifierFlags: [])
        }

        let duringSkimCount = countCacheFiles()

        // Wait through the 500 ms dwell threshold plus a small grace
        // window for the prefetch to land at least one full-res JPG.
        Thread.sleep(forTimeInterval: 1.5)

        let postDwellCount = countCacheFiles()
        XCTAssertGreaterThan(postDwellCount, duringSkimCount,
                             "Dwell should write more cache files than were present during skim")
    }

    private func countCacheFiles() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
            where url.pathExtension == "jpg" {
            count += 1
        }
        return count
    }
```

- [ ] **Step 2: Build for testing to confirm it compiles**

```bash
xcodebuild build-for-testing -scheme SuperPicky -destination 'platform=macOS' 2>&1 | grep -E "error:|TEST BUILD" | grep -v AppIcon | tail -3
```

Expected: TEST BUILD SUCCEEDED.

(L3 tests run on CI per project convention; do not run XCUITests locally.)

- [ ] **Step 3: Commit**

```bash
git add apps/mac-client/SuperPickyUITests/PreviewCacheUITests.swift
git commit -m "test: L3 XCUITest — skim suppresses prefetch until dwell"
```

---

## Task 9: End-to-end verification + open PR

- [ ] **Step 1: Run the full L1 suite once more**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests 2>&1 | grep -E "Test run with|TEST SUC|TEST FAIL" | tail -3
```

Expected: TEST SUCCEEDED, all tests pass.

- [ ] **Step 2: Manual perf cross-check (Release)**

Per Task 7's manual verification — confirm:

- Holding `→` in zoom mode visibly cycles faster than the prior ~4/sec ceiling.
- Single deliberate keypress in zoom mode (no skim) still loads at full-res straight away (no soft → sharp flicker).
- Stopping mid-skim sharpens the current photo within ~250 ms.
- Settings → Advanced → "In-memory cache" readout: count grows on dwell, stable during skim.

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin HEAD
gh pr create --title "Skim/dwell adaptive prefetch" --body "$(cat <<'EOF'
## Summary
Adds a skim/dwell state monitor so prefetch fires only on dwell, and
zoom-mode foreground decode drops to a fast 2000 px preview path during
fast scrubbing. Fast skim now hits ~30/sec instead of the prior ~4/sec
ARW-decode ceiling. Single deliberate keypresses in zoom mode keep their
current behavior (full-res straight away, no soft → sharp flicker).

## Spec
`docs/superpowers/specs/2026-05-02-skim-dwell-prefetch-design.md`

## Changes
- New `NavigationStateMonitor` (`@Observable @MainActor`): classifies
  user input timing into idle / active / skim / dwell. 250 ms skim
  threshold, 500 ms dwell threshold.
- `PrefetchCoordinator.shared` installs an `onEnterDwell` hook so
  prefetch fires once after each dwell instead of per selection change.
- `PreviewView` reads the state at task start; in zoom mode + skim, takes
  the 2000 px preview path. On dwell, upgrades in place to full-res.
- `ContentView` routes selection changes through `note(...)` instead of
  calling `PrefetchCoordinator.update` directly.
- `AppState` resets the monitor on folder switch alongside the existing
  prefetch reset.

## Test plan
- [x] L1 unit tests: 9 new `NavigationStateMonitorTests` covering state
      transitions, dwell timer, hook firing, reset semantics.
- [x] L1 sanity: full suite passes locally.
- [x] L3 XCUITest: `test03_skimSuppressesPrefetchUntilDwell` verifies
      the cache file count grows after dwell but not during skim.
- [x] Manual verification: hold → in zoom mode, observe ~30/sec
      cycling, single keypress unchanged, dwell sharpens within 250 ms.

## Out of scope
The remaining brainstorm angles (burst-end aware prefetch, preview-tier
prefetch for fit mode, filter-change pre-emptive warming, smart hydrate)
are deferred. Each can be pursued independently.
EOF
)"
```

- [ ] **Step 4: Watch CI until green**

Use `gh pr view <pr> --json mergeable,statusCheckRollup` to poll. If a check fails, read the log via `gh run view <run-id> --log-failed`, fix the root cause, push, resume polling.

- [ ] **Step 5: Merge when green**

```bash
gh pr merge <pr> --squash
```

(Per repo convention; no auto-merge unless the operator opts in.)

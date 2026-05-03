# Culling-Perf Tests & Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add unit tests for the recently optimised culling-perf code (PRs #66/#67/#68) by landing three small refactors that open testable seams: extract `ImageCache` from `PreviewView.swift`, extract `AsyncPreviewImage`'s primary-load decision tree into a pure function, and add a sink seam to `PrefetchCoordinator`.

**Architecture:** Three independent refactors, each with TDD cycle and its own commit. Refactor 1 promotes the cache budget computation to a pure free helper. Refactor 2 extracts a 4-case `LoadAction` enum + pure decision function from a SwiftUI `.task` closure. Refactor 3 introduces a `PrefetchSink` protocol so the prefetch orchestration can be tested without `Task.detached`/`ImageLoader`/`ImageCache` side effects, plus a static `computeTargets` pure function for the streak/burst/depth math.

**Tech Stack:** Swift 6 strict concurrency, Swift Testing, `xcodebuild`, `swiftlint`, `OSAllocatedUnfairLock`. Xcode project with explicit `pbxproj` registration (no `xcodegen`/SPM regeneration).

**Reference:** `docs/superpowers/specs/2026-05-03-culling-perf-tests-refactor-design.md`

---

## Conventions used throughout this plan

**Build command** (per `CLAUDE.md`):

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
```

**Test command** (per `CLAUDE.md`):

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests
```

**Targeted test command** (replace `<SuiteName>/<testName>`):

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests/<SuiteName>/<testName>
```

**Defeat stale-build cache** before any `xcodebuild build` after edits (per `CLAUDE.md` retro):

```bash
touch /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/*.swift
```

**`pbxproj` UUID convention.** The recent culling-perf files use the `xxFE12CD3456789012345678` pattern, where `A?` = `PBXBuildFile` UUIDs and `B?` / `C?` / `D?` = `PBXFileReference` UUIDs. New files in this plan use:

| File | Build UUID | FileRef UUID |
|---|---|---|
| `ImageCache.swift` | `A5FE12CD3456789012345678` | `B5FE12CD3456789012345678` |
| `PreviewLoadPolicy.swift` | `A6FE12CD3456789012345678` | `B6FE12CD3456789012345678` |
| `ImageCacheTests.swift` | `A7FE12CD3456789012345678` | `B7FE12CD3456789012345678` |
| `PreviewLoadPolicyTests.swift` | `A8FE12CD3456789012345678` | `B8FE12CD3456789012345678` |
| `PrefetchCoordinatorTests.swift` | `A9FE12CD3456789012345678` | `B9FE12CD3456789012345678` |

---

## Phase 1 — Extract `ImageCache` to its own file (R1)

**Files:**
- Create: `apps/mac-client/SuperPickyApp/ImageCache.swift`
- Create: `apps/mac-client/SuperPickyTests/Core/ImageCacheTests.swift`
- Modify: `apps/mac-client/SuperPickyApp/PreviewView.swift` (remove the moved code)
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj` (register both new files)

### Task 1.1: Write the failing `ImageCacheBudget` tests

- [ ] **Step 1: Create the test file**

Create `apps/mac-client/SuperPickyTests/Core/ImageCacheTests.swift`:

```swift
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
```

### Task 1.2: Confirm the test file fails to compile

- [ ] **Step 1: Build and observe the failure**

Run:
```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -30
```

Expected: build fails — but only because the new test file isn't yet in `project.pbxproj`. To get the type-check failure visible, instead run a syntax check by adding the file to pbxproj first (see Task 1.5) — OR skip ahead to Task 1.3 and let the existence of `ImageCacheBudget` carry the proof. Either is fine; the test only fails compilation if `ImageCacheBudget` doesn't exist.

**Pragmatic approach:** proceed to Task 1.3 to create the type, then Task 1.5 to register it; the test compiles only when both ImageCache and ImageCacheBudget exist. The TDD signal here is "did I forget anything in the move?" — verified by Task 1.6.

### Task 1.3: Create `ImageCache.swift` with the moved code + `ImageCacheBudget`

- [ ] **Step 1: Create the new file**

Create `apps/mac-client/SuperPickyApp/ImageCache.swift`:

```swift
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
```

### Task 1.4: Strip the moved code from `PreviewView.swift`

- [ ] **Step 1: Delete the lines that moved**

In `apps/mac-client/SuperPickyApp/PreviewView.swift`, delete lines 44–169 inclusive (the `ImageCache` doc comment, the `final class ImageCache`, the `ImageCacheDelegate`, and the `Logger.imageCache` extension).

The file's import block stays. The `struct PreviewView: View` (currently lines 4–42) stays. The `struct AsyncPreviewImage: View` (currently starts at line 172) stays.

After the delete, `PreviewView.swift` opens with the `struct PreviewView: View` and immediately follows with the `struct AsyncPreviewImage: View`. Verify with:

```bash
grep -n "ImageCache\|ImageCacheDelegate" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/PreviewView.swift
```

Expected: only references like `ImageCache.fullRes.get(...)` and `ImageCache.preview.set(...)` — no `class ImageCache` or `class ImageCacheDelegate` definitions. The references resolve via the global namespace once `ImageCache.swift` is added to the build target.

### Task 1.5: Register both new files in `project.pbxproj`

- [ ] **Step 1: Add `ImageCache.swift` PBXBuildFile entry**

Edit `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`. After line 161 (the `PreviewSweepCoordinator.swift in Sources` line), insert:

Find this block:
```
		A2FE12CD3456789012345678 /* PreviewSweepCoordinator.swift in Sources */ = {isa = PBXBuildFile; fileRef = B2FE12CD3456789012345678 /* PreviewSweepCoordinator.swift */; };
		A3FE12CD3456789012345678 /* PreviewCacheTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B3FE12CD3456789012345678 /* PreviewCacheTests.swift */; };
```

Insert after the `PreviewSweepCoordinator.swift` line, before `PreviewCacheTests.swift`:
```
		A5FE12CD3456789012345678 /* ImageCache.swift in Sources */ = {isa = PBXBuildFile; fileRef = B5FE12CD3456789012345678 /* ImageCache.swift */; };
		A7FE12CD3456789012345678 /* ImageCacheTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B7FE12CD3456789012345678 /* ImageCacheTests.swift */; };
```

- [ ] **Step 2: Add `ImageCache.swift` PBXFileReference entry**

Find this block in pbxproj (around line 612):
```
		B0FE12CD3456789012345678 /* PreviewCache.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewCache.swift; sourceTree = "<group>"; };
```

After it, insert:
```
		B5FE12CD3456789012345678 /* ImageCache.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ImageCache.swift; sourceTree = "<group>"; };
		B7FE12CD3456789012345678 /* ImageCacheTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ImageCacheTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 3: Add `ImageCache.swift` to the `SuperPickyApp` PBXGroup children**

Find the SuperPickyApp group (the block starting around line 781 with sources like `KeyboardMonitor.swift`, `LaplacianSharpness.swift`). Locate the children list — within it find:
```
			D0FE12CD3456789012345678 /* NavigationStateMonitor.swift */,
```

Right before it (or right after, alphabetical-ish ordering already drifts in this file — group with the other recent additions), add:
```
			B5FE12CD3456789012345678 /* ImageCache.swift */,
```

- [ ] **Step 4: Add `ImageCacheTests.swift` to the `Core` test PBXGroup children**

Find the Core test group (line 713, `2E5D1A7C0537062D38627762 /* Core */ = { ... children = (`). Within its children, after:
```
			51DF18F24F27FA845B8DA10D /* ImageLoaderTests.swift */,
```
insert:
```
			B7FE12CD3456789012345678 /* ImageCacheTests.swift */,
```

- [ ] **Step 5: Add `ImageCache.swift` to the app target's PBXSourcesBuildPhase**

Find the app target's sources list (around line 1568 — the block listing `*.swift in Sources`). After:
```
				EAC14471D1C96D9321F33BC8 /* KeyboardHelpView.swift in Sources */,
```
or near the existing `PreviewCache.swift in Sources` line, add:
```
				A5FE12CD3456789012345678 /* ImageCache.swift in Sources */,
```

- [ ] **Step 6: Add `ImageCacheTests.swift` to the test target's PBXSourcesBuildPhase**

Find the test target's sources list (around line 1481). After:
```
					A3FE12CD3456789012345678 /* PreviewCacheTests.swift in Sources */,
```
insert:
```
					A7FE12CD3456789012345678 /* ImageCacheTests.swift in Sources */,
```

- [ ] **Step 7: Sanity-check the registration**

Run:
```bash
grep -c "ImageCache.swift" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
grep -c "ImageCacheTests.swift" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
```

Expected: each prints `4` (PBXBuildFile + PBXFileReference + PBXGroup children + PBXSourcesBuildPhase).

### Task 1.6: Build, run new tests, run full suite

- [ ] **Step 1: Defeat any stale build cache**

```bash
touch /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/*.swift
```

- [ ] **Step 2: Build**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Warnings-as-errors is on (commit `d94cacb`); any new warning will block.

- [ ] **Step 3: Run only the new test file**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests/ImageCacheBudgetTests 2>&1 | tail -20
```

Expected: 5 tests pass.

- [ ] **Step 4: Run the full unit-test suite**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests 2>&1 | tail -10
```

Expected: every existing suite stays green. The PreviewCache, NavigationStateMonitor, ImageLoader, and any other suite that touches the cache must still pass — the move is behaviour-preserving.

- [ ] **Step 5: Lint**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
  scripts/pre-commit.sh 2>&1 | tail -10
```

Expected: passes. (If swiftlint complains about the moved file's structure, fix inline.)

### Task 1.7: Commit Phase 1

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
git add apps/mac-client/SuperPickyApp/ImageCache.swift \
        apps/mac-client/SuperPickyApp/PreviewView.swift \
        apps/mac-client/SuperPickyTests/Core/ImageCacheTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
refactor(cache): extract ImageCache + pure budget helper

Move ImageCache, ImageCacheDelegate, and Logger.imageCache out of
PreviewView.swift into their own file. Promote the fullRes budget
computation to a pure ImageCacheBudget.compute(physicalMemory:aggressive:)
free helper so tests can exercise the full RAM range without standing
up a real machine. Behaviour at runtime is unchanged — same singletons,
same call sites.

Adds ImageCacheBudgetTests covering the floor, balanced/aggressive
fractions, and the [minBytes, maxBytes] clamp.
EOF
)"
```

---

## Phase 2 — Extract `AsyncPreviewImage` primary-load policy (R2)

**Files:**
- Create: `apps/mac-client/SuperPickyApp/PreviewLoadPolicy.swift`
- Create: `apps/mac-client/SuperPickyTests/Core/PreviewLoadPolicyTests.swift`
- Modify: `apps/mac-client/SuperPickyApp/PreviewView.swift` (rewrite the `.task` body)
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

### Task 2.1: Write the failing `PreviewLoadPolicy` tests

- [ ] **Step 1: Create the test file**

Create `apps/mac-client/SuperPickyTests/Core/PreviewLoadPolicyTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import SuperPicky

/// Exhaustive tests for `decidePrimaryLoad`. The function picks one of four
/// load actions for `AsyncPreviewImage.body.task` based on the
/// `NavigationStateMonitor` state, the current zoom scale, and whether
/// either RAM cache currently has the photo.
///
/// Pinning rule from PreviewView.swift:211 — an in-RAM full-res hit ALWAYS
/// wins, regardless of zoom or skim state — because it's free (no decode,
/// no allocation) and full quality.
struct PreviewLoadPolicyTests {

    // MARK: - .useCachedFullRes wins everywhere

    @Test func cachedFullResWinsAtFitNonSkim() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.0,
                                       hasFullRes: true, hasPreview: false)
        #expect(action == .useCachedFullRes)
    }

    @Test func cachedFullResWinsZoomedNonSkim() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 2.0,
                                       hasFullRes: true, hasPreview: true)
        #expect(action == .useCachedFullRes)
    }

    @Test func cachedFullResWinsEvenInSkim() {
        // PreviewView.swift:211 rule: full-res RAM hit beats the
        // 2000 px preview path even during fast scrubbing.
        let action = decidePrimaryLoad(state: .skim, zoomScale: 2.0,
                                       hasFullRes: true, hasPreview: false)
        #expect(action == .useCachedFullRes)
    }

    // MARK: - Zoomed, not skim → load full-res direct

    @Test func zoomedActiveLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadFullResDirect)
    }

    @Test func zoomedDwellLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .loadFullResDirect)
    }

    @Test func zoomedIdleLoadsFullResDirect() {
        let action = decidePrimaryLoad(state: .idle, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadFullResDirect)
    }

    // MARK: - Skim in zoom → preview-tier path

    @Test func skimZoomedUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }

    @Test func skimZoomedLoadsPreviewWhenColdCache() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.5,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadPreview)
    }

    // MARK: - Fit (zoom == 1) → preview-tier path regardless of state

    @Test func fitActiveUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .active, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }

    @Test func fitSkimLoadsPreview() {
        let action = decidePrimaryLoad(state: .skim, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: false)
        #expect(action == .loadPreview)
    }

    @Test func fitDwellUsesCachedPreview() {
        let action = decidePrimaryLoad(state: .dwell, zoomScale: 1.0,
                                       hasFullRes: false, hasPreview: true)
        #expect(action == .useCachedPreview)
    }
}
```

### Task 2.2: Confirm the test file fails to compile

- [ ] **Step 1: Try to build (or skip and proceed to Task 2.3)**

The test references `decidePrimaryLoad` and `LoadAction` which don't yet exist. Either build now to see the failure, or skip ahead — the build will catch any signature drift in Task 2.6 either way.

### Task 2.3: Create `PreviewLoadPolicy.swift`

- [ ] **Step 1: Create the new file**

Create `apps/mac-client/SuperPickyApp/PreviewLoadPolicy.swift`:

```swift
import Foundation
import CoreGraphics

/// One of four load strategies `AsyncPreviewImage.body.task` chooses
/// between for the *primary* image load on a selection change. The
/// dwell-preload tail and the zoom/state `onChange` upgrade handlers
/// run separately in the same view; this enum only governs the first
/// pass.
enum LoadAction: Equatable, Sendable {
    /// In-RAM full-res cache hit. Take it regardless of zoom/skim — it
    /// is free (no decode, no allocation) and full quality.
    case useCachedFullRes
    /// Zoom > 1 with no skim signal: decode straight to full resolution
    /// so a deliberate zoomed inspection isn't soft-then-sharp.
    case loadFullResDirect
    /// 2000 px preview-tier RAM hit.
    case useCachedPreview
    /// 2000 px preview-tier decode (skim-in-zoom or fit-mode default).
    case loadPreview
}

/// Decide which load path `AsyncPreviewImage.body.task` should take for
/// the next photo. Pure: takes only observable inputs, returns a tagged
/// enum. Lets the policy be exhaustively tested without SwiftUI or
/// ImageIO.
///
/// Decision order (each rule short-circuits):
/// 1. Full-res RAM hit → reuse it (free, sharp). Wins even in skim.
/// 2. Zoom > 1 and not in skim → take the full-res decode path.
/// 3. Preview-tier RAM hit → reuse it.
/// 4. Otherwise → 2000 px decode (skim-in-zoom takes this; so does fit).
func decidePrimaryLoad(
    state: NavigationStateMonitor.State,
    zoomScale: CGFloat,
    hasFullRes: Bool,
    hasPreview: Bool
) -> LoadAction {
    if hasFullRes { return .useCachedFullRes }
    if zoomScale > 1.0 && state != .skim { return .loadFullResDirect }
    if hasPreview { return .useCachedPreview }
    return .loadPreview
}
```

### Task 2.4: Refactor `AsyncPreviewImage.body.task` to switch on `decidePrimaryLoad`

- [ ] **Step 1: Replace the `.task(id: filePath) { ... }` body**

In `apps/mac-client/SuperPickyApp/PreviewView.swift`, locate the `.task(id: filePath) { ... }` block (currently around lines 209–252 — the line numbers will have shifted after Phase 1's deletion; locate it as the `.task(id: filePath)` modifier on the `ZStack` inside `AsyncPreviewImage.body`).

Replace the entire `.task` closure with:

```swift
        .task(id: filePath) {
            isFullRes = false
            let action = decidePrimaryLoad(
                state: NavigationStateMonitor.shared.state,
                zoomScale: zoomState.scale,
                hasFullRes: ImageCache.fullRes.get(filePath) != nil,
                hasPreview: ImageCache.preview.get(filePath) != nil
            )
            switch action {
            case .useCachedFullRes:
                image = ImageCache.fullRes.get(filePath)
                isFullRes = true
                return
            case .loadFullResDirect:
                if let full = await loadFullRes(filePath) {
                    guard !Task.isCancelled else { return }
                    image = full
                    isFullRes = true
                }
                return
            case .useCachedPreview:
                image = ImageCache.preview.get(filePath)
            case .loadPreview:
                if let loaded = await ImageLoader.load(path: filePath, maxPixelSize: 2000) {
                    guard !Task.isCancelled else { return }
                    ImageCache.preview.set(filePath, image: loaded)
                    image = loaded
                }
            }
            // Dwell-preload: rebinding an 80 MB NSImage while at fit scale
            // forces a main-thread redraw that stalls arrow-key handling, so
            // we only warm the full-res cache — zoom picks it up later.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if ImageCache.fullRes.get(filePath) != nil { return }
            if let size = ImageLoader.pixelSize(path: filePath), max(size.width, size.height) <= 2000 {
                if let current = image { ImageCache.fullRes.set(filePath, image: current) }
                return
            }
            if let full = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                if Task.isCancelled { return }
                ImageCache.fullRes.set(filePath, image: full)
            }
        }
```

The `.onChange(of: zoomState.scale)` and `.onChange(of: NavigationStateMonitor.shared.state)` modifiers stay exactly as they are.

- [ ] **Step 2: Confirm no other file references the inlined logic**

```bash
grep -rn "useCachedFullRes\|loadFullResDirect\|useCachedPreview\|loadPreview\|decidePrimaryLoad" \
  /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/
```

Expected: results only in `PreviewLoadPolicy.swift` and the rewritten `PreviewView.swift` `.task` body.

### Task 2.5: Register both new files in `project.pbxproj`

- [ ] **Step 1: Add PBXBuildFile entries**

Find the same block as Phase 1 Step 1 (the `PreviewSweepCoordinator.swift in Sources` line). Add after the lines added in Phase 1:
```
		A6FE12CD3456789012345678 /* PreviewLoadPolicy.swift in Sources */ = {isa = PBXBuildFile; fileRef = B6FE12CD3456789012345678 /* PreviewLoadPolicy.swift */; };
		A8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift */; };
```

- [ ] **Step 2: Add PBXFileReference entries**

After the `B7FE12CD3456789012345678 /* ImageCacheTests.swift */` reference added in Phase 1, insert:
```
		B6FE12CD3456789012345678 /* PreviewLoadPolicy.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewLoadPolicy.swift; sourceTree = "<group>"; };
		B8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PreviewLoadPolicyTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 3: Add `PreviewLoadPolicy.swift` to the SuperPickyApp PBXGroup**

In the same group as `ImageCache.swift` (added in Phase 1 Step 3), insert near the other `Preview*` files:
```
			B6FE12CD3456789012345678 /* PreviewLoadPolicy.swift */,
```

- [ ] **Step 4: Add `PreviewLoadPolicyTests.swift` to the Core test PBXGroup**

After the `B7FE12CD3456789012345678 /* ImageCacheTests.swift */` line added in Phase 1 Step 4, insert:
```
			B8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift */,
```

- [ ] **Step 5: Add `PreviewLoadPolicy.swift` to the app target's PBXSourcesBuildPhase**

After the `A5FE12CD3456789012345678 /* ImageCache.swift in Sources */` line from Phase 1 Step 5, insert:
```
				A6FE12CD3456789012345678 /* PreviewLoadPolicy.swift in Sources */,
```

- [ ] **Step 6: Add `PreviewLoadPolicyTests.swift` to the test target's PBXSourcesBuildPhase**

After the `A7FE12CD3456789012345678 /* ImageCacheTests.swift in Sources */` line from Phase 1 Step 6, insert:
```
					A8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift in Sources */,
```

- [ ] **Step 7: Sanity-check**

```bash
grep -c "PreviewLoadPolicy.swift" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
grep -c "PreviewLoadPolicyTests.swift" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
```

Expected: each prints `4`.

### Task 2.6: Build, run new tests, run full suite, smoke-check the app

- [ ] **Step 1: Defeat stale build cache**

```bash
touch /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/*.swift
```

- [ ] **Step 2: Build**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run only the new test file**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests/PreviewLoadPolicyTests 2>&1 | tail -20
```

Expected: 11 tests pass.

- [ ] **Step 4: Run full unit suite**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests 2>&1 | tail -10
```

Expected: every existing suite stays green. The behaviour-equivalence claim is "the switch reproduces the same path the inline code took for every (state, zoom, hit) combination" — `PreviewLoadPolicyTests` proves that statically.

- [ ] **Step 5: Lint**

```bash
cd /Users/dazhen/projects/SuperPickyMac && scripts/pre-commit.sh 2>&1 | tail -5
```

Expected: passes.

### Task 2.7: Commit Phase 2

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
git add apps/mac-client/SuperPickyApp/PreviewLoadPolicy.swift \
        apps/mac-client/SuperPickyApp/PreviewView.swift \
        apps/mac-client/SuperPickyTests/Core/PreviewLoadPolicyTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
refactor(preview): extract primary-load decision into pure func

AsyncPreviewImage.body.task carried a 4-branch decision tree inline
(skim vs zoom vs full-res hit vs preview hit). Pull it out as a pure
decidePrimaryLoad(state:zoomScale:hasFullRes:hasPreview:) -> LoadAction
helper. The .task body becomes a switch over the result; dwell-preload
tail and the .onChange upgrade handlers stay inline as effects.

Adds PreviewLoadPolicyTests covering the full 4-state × 2-zoom × 2 × 2
input matrix, including the "in-RAM full-res hit wins even during skim"
rule from PreviewView.swift:211.
EOF
)"
```

---

## Phase 3 — Add `PrefetchSink` seam + extract `computeTargets` (R3)

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift`
- Create: `apps/mac-client/SuperPickyTests/Core/PrefetchCoordinatorTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

### Task 3.1: Write the failing `PrefetchTargets` tests (pure-func half)

- [ ] **Step 1: Create the test file with both suites**

Create `apps/mac-client/SuperPickyTests/Core/PrefetchCoordinatorTests.swift`:

```swift
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
        // No burst → all targets come from "next bursts" path. After streak
        // updates to 6, boost = 10, depth = 16. Forward from index 5 in
        // a 30-photo folder, at most 16 photos collected.
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

    @Test func prefillResetsStreakAndUpdates() async {
        let recorder = RecorderSink()
        let coord = PrefetchCoordinator(sink: recorder)
        coord.prefill(photos: plainPhotos(30), around: 10)
        #expect(!recorder.warmed.isEmpty,
                "prefill must run an update so the initial RAM cache fills")
    }
}
```

### Task 3.2: Confirm the test file fails to compile

- [ ] **Step 1: Skip ahead**

`PrefetchCoordinator.computeTargets`, the `PrefetchSink` protocol, and the `init(sink:)` initialiser don't exist yet. Skip building until Task 3.5 lands the production-side changes; we'll see the green signal at Task 3.7.

### Task 3.3: Extract `computeTargets` and route `update()` through it (no public API change yet)

- [ ] **Step 1: Open `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift`**

- [ ] **Step 2: Replace the existing `update`, `updateStreak`, `sameBurstSortedByNavDistance`, `nextBurstsPhotos`, and `maxTargets` const with a single static `computeTargets` plus a thin `update`**

Within `final class PrefetchCoordinator`, replace the body of `update(currentIndex:photos:)` and the helpers below it. The new shape:

```swift
    /// Cap how many photos we ever queue at once. Above this, churning
    /// through prefetches costs more than the cache hits save.
    static let maxTargets = 40

    /// Pure: derives the next streak, navigation step, and ordered prefetch
    /// target list for a given selection. No I/O, no actor hops, no
    /// observable side effects — fully testable.
    static func computeTargets(
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
    private static func nextStreak(currentIndex: Int, lastIndex: Int?, streak: Int) -> (Int, Int) {
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
    private static func sameBurstSortedByNavDistance(in photos: [Photo],
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
    private static func nextBurstsPhotos(from index: Int,
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
            if ImageCache.fullRes.get(path) != nil { continue }
            scheduleWarm(path: path)
            scheduled += 1
        }

        let current = photos[currentIndex]
        Self.log.info(
            "update idx=\(currentIndex) step=\(step) streak=\(self.streak) burst=\(current.burstGroupID?.uuidString.prefix(4) ?? "—", privacy: .public) targets=\(targets.count) cancelled=\(cancelled) scheduled=\(scheduled) inflight=\(self.inflight.count)"
        )
    }
```

Delete the old instance-level `updateStreak`, `sameBurstSortedByNavDistance`, `nextBurstsPhotos`, and the inline `private static let maxTargets = 40` (we promoted it to `static`/`internal`).

The existing `scheduleWarm`, `inflightDidComplete`, `prefill`, `reset`, and `bootstrap` stay as they are for now. The class is still `@MainActor`. Logging output remains identical.

### Task 3.4: Verify pure tests pass and behaviour is unchanged

- [ ] **Step 1: Defeat stale build cache and build**

```bash
touch /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/*.swift && \
  cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. (Test target won't include the new test file yet — that's fine; we register it after Task 3.5.)

- [ ] **Step 2: Run the existing prefetch-touching suites**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests 2>&1 | tail -10
```

Expected: every existing suite stays green. The `update()` orchestration is unchanged in observable behaviour; we just lifted the math out.

### Task 3.5: Add the `PrefetchSink` protocol, `LiveImageCacheSink`, and the injectable initialiser

- [ ] **Step 1: Add the protocol and live sink at the top of `PrefetchCoordinator.swift`**

In `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift`, after the `import` block and before `@MainActor final class PrefetchCoordinator`, add:

```swift
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
```

- [ ] **Step 2: Promote `log` from `fileprivate` to `internal` so `LiveImageCacheSink` can use it**

Change:
```swift
fileprivate static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")
```
to:
```swift
static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")
```

- [ ] **Step 3: Inject the sink at init and rewire `update()` and `scheduleWarm`**

In the same file:

```swift
@MainActor
final class PrefetchCoordinator {
    static let shared = PrefetchCoordinator(sink: LiveImageCacheSink())
    static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "Prefetch")

    private let sink: PrefetchSink

    init(sink: PrefetchSink) { self.sink = sink }

    func bootstrap() {
        NavigationStateMonitor.shared.onEnterDwell = { [weak self] index, photos in
            self?.update(currentIndex: index, photos: photos)
        }
    }

    // … baseNextBurstDepth, maxNextBurstDepth, streak, lastIndex,
    // inflight, prefill, computeTargets, helpers, reset stay as-is …

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
            inflight[path] = Task { @MainActor [weak self] in
                _ = await inner.value
                self?.inflight.removeValue(forKey: path)
            }
            scheduled += 1
        }

        let current = photos[currentIndex]
        Self.log.info(
            "update idx=\(currentIndex) step=\(step) streak=\(self.streak) burst=\(current.burstGroupID?.uuidString.prefix(4) ?? "—", privacy: .public) targets=\(targets.count) cancelled=\(cancelled) scheduled=\(scheduled) inflight=\(self.inflight.count)"
        )
    }
```

- [ ] **Step 4: Delete `scheduleWarm` and `inflightDidComplete`**

Their bodies are now folded into `update()`'s sink call + completion wrapper. Delete:

```swift
private func scheduleWarm(path: String) { … }
fileprivate func inflightDidComplete(path: String) { … }
```

- [ ] **Step 5: Confirm no other file referenced the deleted helpers**

```bash
grep -rn "scheduleWarm\|inflightDidComplete" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/
```

Expected: no matches. (If any do remain, restore the helpers — they were only deleted because they're called from one place.)

### Task 3.6: Register `PrefetchCoordinatorTests.swift` in `project.pbxproj`

- [ ] **Step 1: Add PBXBuildFile entry**

After the previously added test PBXBuildFile entries (`A8FE12CD…`), insert:
```
		A9FE12CD3456789012345678 /* PrefetchCoordinatorTests.swift in Sources */ = {isa = PBXBuildFile; fileRef = B9FE12CD3456789012345678 /* PrefetchCoordinatorTests.swift */; };
```

- [ ] **Step 2: Add PBXFileReference entry**

After the `B8FE12CD…` reference, insert:
```
		B9FE12CD3456789012345678 /* PrefetchCoordinatorTests.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PrefetchCoordinatorTests.swift; sourceTree = "<group>"; };
```

- [ ] **Step 3: Add to the Core test PBXGroup children**

After `B8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift */,` insert:
```
			B9FE12CD3456789012345678 /* PrefetchCoordinatorTests.swift */,
```

- [ ] **Step 4: Add to the test target's PBXSourcesBuildPhase**

After `A8FE12CD3456789012345678 /* PreviewLoadPolicyTests.swift in Sources */,` insert:
```
					A9FE12CD3456789012345678 /* PrefetchCoordinatorTests.swift in Sources */,
```

- [ ] **Step 5: Sanity-check**

```bash
grep -c "PrefetchCoordinatorTests.swift" /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
```

Expected: `4`.

### Task 3.7: Build, run new tests, run full suite

- [ ] **Step 1: Defeat stale build cache and build**

```bash
touch /Users/dazhen/projects/SuperPickyMac/apps/mac-client/SuperPickyApp/*.swift && \
  cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run only the new test file**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests/PrefetchTargetsTests \
  -only-testing:SuperPickyTests/PrefetchOrchestrationTests 2>&1 | tail -30
```

Expected: 9 + 6 = 15 tests pass.

- [ ] **Step 3: Run full unit suite**

```bash
cd /Users/dazhen/projects/SuperPickyMac/apps/mac-client && \
  xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
  -only-testing:SuperPickyTests 2>&1 | tail -10
```

Expected: every existing suite stays green. The wrap-in-own-task change has the same observable behaviour as the old `inflightDidComplete` callback — the entry is removed from `inflight` when the warm task completes.

- [ ] **Step 4: Lint**

```bash
cd /Users/dazhen/projects/SuperPickyMac && scripts/pre-commit.sh 2>&1 | tail -5
```

Expected: passes.

### Task 3.8: Commit Phase 3

- [ ] **Step 1: Stage and commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
git add apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift \
        apps/mac-client/SuperPickyTests/Core/PrefetchCoordinatorTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj && \
git commit -m "$(cat <<'EOF'
refactor(prefetch): extract pure target math + add sink seam

Pull the streak/burst/depth math out of update() into a pure static
PrefetchCoordinator.computeTargets(currentIndex:photos:lastIndex:streak:)
helper. Add a PrefetchSink protocol so update()'s cancel/schedule/diff
can be tested without Task.detached / ImageLoader / ImageCache side
effects. Production uses LiveImageCacheSink (unchanged behaviour).
Coordinator now wraps the sink's warm task in its own MainActor task
that owns the inflight bookkeeping — the previous shared-singleton
inflightDidComplete callback is gone.

Adds PrefetchTargetsTests (pure: 9 cases — streak math, burst-aware
ordering, depth boost, cap, edges) and PrefetchOrchestrationTests
(via RecorderSink: 6 cases — schedule, diff, cancel, cache-skip, reset,
prefill).
EOF
)"
```

---

## Phase 4 — Push and open PR

### Task 4.1: Push the branch

- [ ] **Step 1: Confirm branch state**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
  git log --oneline main..HEAD && git status
```

Expected: 3 new commits since `main`, clean working tree.

- [ ] **Step 2: Push**

```bash
cd /Users/dazhen/projects/SuperPickyMac && git push -u origin HEAD
```

### Task 4.2: Open PR

- [ ] **Step 1: Open the PR**

```bash
cd /Users/dazhen/projects/SuperPickyMac && \
gh pr create --title "Tests + small refactors for culling-perf code" --body "$(cat <<'EOF'
## Summary
- Extract `ImageCache` (and a pure `ImageCacheBudget.compute` helper) out of `PreviewView.swift` into its own file. Adds 5 test cases for the budget math.
- Extract `AsyncPreviewImage`'s primary-load decision tree into a pure `decidePrimaryLoad(state:zoomScale:hasFullRes:hasPreview:) -> LoadAction` helper. Adds 11 test cases covering the 4-state × 2-zoom × 2 × 2 input matrix.
- Add a `PrefetchSink` protocol seam to `PrefetchCoordinator` and lift the streak/burst/depth math into a pure `static computeTargets(...)` helper. Adds 9 + 6 test cases (pure targets + orchestration via fake sink).

No behaviour change. Backfills coverage for the recent culling-perf optimisation work (#66/#67/#68).

Spec: `docs/superpowers/specs/2026-05-03-culling-perf-tests-refactor-design.md`
Plan: `docs/superpowers/plans/2026-05-03-culling-perf-tests-refactor.md`

## Test plan
- [x] `xcodebuild test -only-testing:SuperPickyTests/ImageCacheBudgetTests` — 5 pass
- [x] `xcodebuild test -only-testing:SuperPickyTests/PreviewLoadPolicyTests` — 11 pass
- [x] `xcodebuild test -only-testing:SuperPickyTests/PrefetchTargetsTests` — 9 pass
- [x] `xcodebuild test -only-testing:SuperPickyTests/PrefetchOrchestrationTests` — 6 pass
- [x] `xcodebuild test -only-testing:SuperPickyTests` — full suite green
- [x] `scripts/pre-commit.sh` — lint clean
EOF
)"
```

- [ ] **Step 2: Watch CI to green**

Per the user's standing CLAUDE.md rule (`feedback_ci_watch_until_green`):

```bash
gh pr checks --watch
```

If anything goes red, diagnose and push fixes until green. Hand back only once every required check is green.

---

## Self-review

**Spec coverage**

| Spec section | Tasks |
|---|---|
| R1 — `ImageCache.swift` extraction | Phase 1 (Tasks 1.1–1.7) |
| R2 — `PreviewLoadPolicy.swift` | Phase 2 (Tasks 2.1–2.7) |
| R3 — `PrefetchCoordinator` seams | Phase 3 (Tasks 3.1–3.8) |
| `ImageCacheTests.swift` (5 cases) | Task 1.1 |
| `PreviewLoadPolicyTests.swift` (~11 cases) | Task 2.1 |
| `PrefetchCoordinatorTests.swift` (9 + 6 cases) | Task 3.1 |
| `pbxproj` registration for all new files | Tasks 1.5, 2.5, 3.6 |
| Build + full-suite + lint after each phase | Tasks 1.6, 2.6, 3.7 |
| Push + PR + watch CI to green | Phase 4 |
| Out-of-scope items (no `ImageLoader` split, no L3, no skim/dwell behaviour change) | Honoured throughout — `ImageLoader.swift`, `NavigationStateMonitor.swift`, `PreviewCache.swift`, `PreviewCacheUITests.swift` are not modified |

**Type/signature consistency**

- `decidePrimaryLoad(state:zoomScale:hasFullRes:hasPreview:)` — same signature in spec (R2), file create (Task 2.3), test file (Task 2.1), and `.task` rewrite (Task 2.4).
- `LoadAction` cases — `.useCachedFullRes` / `.loadFullResDirect` / `.useCachedPreview` / `.loadPreview` — same in all four locations.
- `PrefetchSink.has(_:)` and `warm(_:) -> Task<Void, Never>` — same in protocol decl (Task 3.5), `LiveImageCacheSink` (Task 3.5), `RecorderSink` (Task 3.1), and `update()` call sites (Task 3.5).
- `PrefetchCoordinator.computeTargets(currentIndex:photos:lastIndex:streak:) -> (newStreak: Int, step: Int, targets: [String])` — same in spec, Task 3.3 declaration, and all 9 `PrefetchTargetsTests` invocations in Task 3.1.
- `init(sink:)` — same in Task 3.5 declaration and every `RecorderSink` test in Task 3.1.

**Placeholder scan**

- No `TBD`, `TODO`, `implement later`, or `similar to Task N` references.
- Every code step shows the actual code.
- Every shell step shows the exact command and expected output prefix.

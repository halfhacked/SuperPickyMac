# Culling-Perf Tests & Refactor — Design

## Context

Three PRs (#66 disk+RAM preview cache, #67 skim/dwell adaptive prefetch, #68 explicit prefetch bootstrap) reshaped the photo-loading hot path. The result performs well but left maintainability gaps:

- **`PrefetchCoordinator` has zero tests.** The streak math, burst-aware target ordering, anti-thrash diff, and depth boost all ship uncovered. The original spec promised a `PrefetchCoordinatorWiringTests` suite (`docs/superpowers/specs/2026-05-02-skim-dwell-prefetch-design.md` §Testing) but it never landed.
- **`ImageCache` lives inside `PreviewView.swift` (~115 LOC of cache wrapper + RAM budget policy + bookkeeping mirror)** and has no tests. The byte-budget computation hard-reads `ProcessInfo.processInfo.physicalMemory` and `PreviewCache.settings.aggressiveCache`, so it can't be exercised at small RAM sizes.
- **`AsyncPreviewImage.body.task`** in `PreviewView.swift:209–252` carries a 40-line decision tree (skim vs zoom vs cache hit vs preview tier) inline. Every branch only exercises through SwiftUI + a real ImageIO decode, so the policy is effectively untestable.

The goal is to land tests for the meaty hot-path logic and ship the minimal refactors that make those tests possible — no behavior change, no broader cleanup.

## Approach

Three small, focused refactors that each open up a unit-testable surface, plus four new test files.

| Refactor | What | Why |
|---|---|---|
| **R1.** Extract `ImageCache` to its own file. | Move the class + the `ImageCacheDelegate` + `Logger.imageCache` + the `preview`/`fullRes` singletons out of `PreviewView.swift`. Promote `computeFullResBudget` to a pure free helper `ImageCacheBudget.compute(physicalMemory:aggressive:)`. | Lets us test budget math at synthetic memory sizes. Cleans up `PreviewView.swift`, which currently mixes a SwiftUI view, a cache class, and the cache wrapper's NSCache delegate. |
| **R2.** Extract `AsyncPreviewImage`'s primary-load policy. | Pull the decision tree (lines 209–252 of `PreviewView.swift`) into a pure free function `decidePrimaryLoad(state:zoomScale:hasFullRes:hasPreview:) -> LoadAction` returning a `LoadAction` enum. The `.task` body becomes a switch over the result. The dwell-preload tail and `.onChange` upgrade handlers stay inline. | The decision tree is the bug-prone bit (it's where #67 reshaped behavior). Pure func is exhaustively testable in <1 ms. |
| **R3.** Add a sink seam to `PrefetchCoordinator`. | Extract the burst+streak math into `static func computeTargets(currentIndex:photos:lastIndex:streak:) -> (newStreak: Int, step: Int, targets: [String])`. Introduce `protocol PrefetchSink { func has(_:); func warm(_:) -> Task<Void, Never> }` injected at init. Production sink wraps `ImageLoader.loadCGImagePrefetch` + `ImageCache.fullRes`. | The pure target math tests directly. The orchestration (cancel/schedule/in-flight diff) tests through a recorder sink with no Image IO. |

No `ImageLoader` split, no `decodeCore` refactor, no behavior change to the skim/dwell state machine, no L3 changes. The disk JPG cache, RAM caches, prefetch decode queue, and cache-write queue all stay exactly as they are.

## Refactor details

### R1 — `ImageCache.swift` extraction

**New file** `apps/mac-client/SuperPickyApp/ImageCache.swift`. Moves verbatim from `PreviewView.swift`:
- `final class ImageCache` and its singletons (`preview`, `fullRes`).
- `private final class ImageCacheDelegate`.
- `extension Logger { fileprivate static let imageCache = ... }` (becomes `internal` since two files now reference it).

Refactor: `computeFullResBudget` (currently a `static func` reading globals) becomes a pure free helper:

```swift
enum ImageCacheBudget {
    static let estimatedEntryBytes = 96 * 1024 * 1024
    static let minBytes = 800 * 1024 * 1024
    static let maxBytes = 32 * 1024 * 1024 * 1024  // 32 GB

    static func compute(physicalMemory: UInt64, aggressive: Bool) -> (count: Int, bytes: Int) {
        let fraction = aggressive ? 0.5 : 0.25
        let raw = Int(Double(physicalMemory) * fraction)
        let bytes = max(minBytes, min(maxBytes, raw))
        return (max(8, bytes / estimatedEntryBytes), bytes)
    }
}
```

`ImageCache.fullRes` initializer calls `ImageCacheBudget.compute(physicalMemory: ProcessInfo.processInfo.physicalMemory, aggressive: PreviewCache.settings.aggressiveCache)` — exact same runtime behavior at the boot site.

Update `SuperPicky.xcodeproj/project.pbxproj`: register `ImageCache.swift` in PBXBuildFile / PBXFileReference / PBXGroup children / PBXSourcesBuildPhase (per CLAUDE.md).

### R2 — `PreviewLoadPolicy.swift`

**New file** `apps/mac-client/SuperPickyApp/PreviewLoadPolicy.swift`:

```swift
enum LoadAction: Equatable {
    case useCachedFullRes        // RAM hit, regardless of zoom/state
    case loadFullResDirect       // zoom > 1, not skim, no full-res cache
    case useCachedPreview        // 2000 px RAM hit
    case loadPreview             // 2000 px decode (skim or fit-mode default)
}

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

`AsyncPreviewImage.body.task` (in `PreviewView.swift`) becomes:

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
    // Dwell-preload tail (sleep 400 ms, warm fullRes) — unchanged from current.
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

Both `.onChange(of: zoomState.scale)` and `.onChange(of: NavigationStateMonitor.shared.state)` upgrade handlers stay exactly as they are — they're sequence/effect, not the primary decision.

Register the new file in `project.pbxproj`.

### R3 — `PrefetchCoordinator` seams

**Edit** `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift`:

```swift
@MainActor
protocol PrefetchSink {
    func has(_ path: String) -> Bool
    func warm(_ path: String) -> Task<Void, Never>
}

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
                }
            }
        }
    }
}

@MainActor
final class PrefetchCoordinator {
    static let shared = PrefetchCoordinator(sink: LiveImageCacheSink())

    private let sink: PrefetchSink
    init(sink: PrefetchSink) { self.sink = sink }

    /// Pure: derives next streak, navigation step, and the ordered prefetch
    /// target list for a given selection. No I/O, no actor hops.
    static func computeTargets(
        currentIndex: Int,
        photos: [Photo],
        lastIndex: Int?,
        streak: Int
    ) -> (newStreak: Int, step: Int, targets: [String]) {
        // Body lifted from the current update() / updateStreak() /
        // sameBurstSortedByNavDistance() / nextBurstsPhotos() helpers.
    }

    func update(currentIndex: Int, photos: [Photo]) {
        guard photos.indices.contains(currentIndex) else { return }
        let (newStreak, _, targets) = Self.computeTargets(
            currentIndex: currentIndex, photos: photos, lastIndex: lastIndex, streak: streak
        )
        streak = newStreak
        lastIndex = currentIndex

        let desired = Set(targets)
        for (path, task) in inflight where !desired.contains(path) {
            task.cancel()
            inflight.removeValue(forKey: path)
        }
        for path in targets {
            if inflight[path] != nil { continue }
            if sink.has(path) { continue }
            let inner = sink.warm(path)
            // Wrap in our own task so completion bookkeeping stays here,
            // not in the sink. Sink stays a pure decode-and-write helper.
            inflight[path] = Task { @MainActor [weak self] in
                _ = await inner.value
                self?.inflight.removeValue(forKey: path)
            }
        }
    }
}
```

Logging stays identical to current. The `Self.maxTargets = 40` cap moves into `computeTargets` (it currently lives inline in `update()`).

Tests construct `PrefetchCoordinator(sink: RecorderSink())` for orchestration tests; the live `.shared` singleton is unchanged at runtime.

## Test additions

### `ImageCacheTests.swift` (new, ~60 LOC, Swift Testing)

Pure-function tests on `ImageCacheBudget.compute`:

| Test | Input | Expectation |
|---|---|---|
| `floorOnLowMemoryMac` | 8 GB, balanced | bytes == minBytes (800 MB), count ≥ 8 |
| `balancedScalesWith25Percent` | 64 GB, balanced | bytes ≈ 16 GB, count == bytes / 96 MB |
| `aggressiveDoublesBudget` | 64 GB, aggressive | bytes ≈ 32 GB (clamped), count proportional |
| `ceilingClampsHugeMemory` | 256 GB, aggressive | bytes capped at maxBytes (32 GB) |
| `countNeverBelowEight` | tiny synthetic memory | count == 8 |

### `PreviewLoadPolicyTests.swift` (new, ~80 LOC, Swift Testing)

Exhaustive matrix of `decidePrimaryLoad`:

| state | zoom | hasFullRes | hasPreview | expected |
|---|---|---|---|---|
| any | any | true | any | `.useCachedFullRes` |
| .idle / .active / .dwell | 1.5 | false | true | `.loadFullResDirect` |
| .idle / .active / .dwell | 1.5 | false | false | `.loadFullResDirect` |
| .skim | 1.5 | false | true | `.useCachedPreview` |
| .skim | 1.5 | false | false | `.loadPreview` |
| any | 1.0 | false | true | `.useCachedPreview` |
| any | 1.0 | false | false | `.loadPreview` |

Plus a `cachedFullResWinsEvenInSkim` test pinning `PreviewView.swift:211`'s rule ("Always prefer an in-RAM full-res hit, even during skim").

### `PrefetchCoordinatorTests.swift` (new, ~200 LOC, Swift Testing)

Two sub-suites in one file.

**`PrefetchTargetsTests` — pure `computeTargets`:**
- `firstCallNoStreakDefaultsForward` — `lastIndex = nil`, `step == 1`, `newStreak == streak` (unchanged on first call).
- `forwardThenForwardExtendsStreak` — last=5, current=6, streak=1 → newStreak == 2.
- `reversalResetsStreak` — last=10, streak=+5, current=9 → newStreak == -1.
- `sameIndexKeepsDirection` — last=5, streak=+3, current=5 → step == +1, streak unchanged.
- `sameBurstFirstNextBurstAfter` — fixture with a 3-photo burst at index 2..4, plain photos elsewhere; from index 3, targets contains burst-mates 4, 2 before next-burst photos.
- `nextBurstDepthRespectsBoost` — streak == +5 → next-burst depth == 6 + 8 == 14, capped at maxNextBurstDepth (30).
- `targetsCappedAtMaxTargets` — long folder + large boost → `targets.count <= 40`.
- `singlePhotoFolder` — one photo, current = 0 → empty targets, no crash.
- `outOfRangeIndexEmpty` — current = -1 or > count → empty targets, streak unchanged.

**`PrefetchOrchestrationTests` — `update()` via fake sink:**

```swift
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
            await Task.yield()
            if Task.isCancelled { self?.cancelled.append(p) }
        }
    }
}
```

- `firstUpdateSchedulesAllTargets` — fresh coordinator, update at idx 5 → `recorder.warmed` matches `computeTargets` output.
- `inflightSurvivesAdjacentMove` — update(5) then update(6); paths still in target set are NOT re-warmed (no duplicate entries in `recorder.warmed`).
- `outOfSetIsCancelled` — update(5), then jump to idx=80; old target tasks land in `recorder.cancelled` after the orchestration runs.
- `cachedPathSkipped` — `recorder.present = {"p10"}` before update; `recorder.warmed` excludes `"p10"`.
- `resetCancelsEverything` — after update, call `reset()` → all inflight cancelled, streak == 0, lastIndex == nil.
- `prefillResetsStreakAndCallsUpdate` — verifies the bootstrap path.

### `ImageLoaderTests` — not extended in this PR

The route-selection gate (`maxPixelSize <= 320` → concurrent thumbnail queue, else → `ImageDecodeQueue`) is timing-dependent and only observable via wall-clock ordering against a real ARW fixture. We could assert it via parallel `loadCGImage` calls + completion timestamps, but the test is inherently flake-prone on CI's shared runner and there's no non-timing seam without a deeper `ImageLoader` refactor (which is out of scope per Section "Out of scope"). Existing `largeJPGWithTinyEmbeddedThumbnail_decodesFullImageNotThumb` (the #47 regression) stays as the only `ImageLoader` test.

**Total new test code: ~340 LOC across 3 files.**

## Edge cases & error handling

| Case | Plan |
|---|---|
| Inflight bookkeeping needs to clear on task completion. Today the live warm task calls `PrefetchCoordinator.shared.inflightDidComplete(path:)` directly — that breaks if a non-singleton coordinator ever uses the live sink. | Coordinator wraps each `sink.warm(path)` in its own MainActor task that awaits and removes the entry from `inflight`. Sink stays pure (decode + cache write). `inflightDidComplete` deleted. |
| `ImageCacheBudget.compute` with `physicalMemory == 0` (synthetic). | Must still return count ≥ 8, bytes == minBytes. |
| `PreviewLoadPolicy` doesn't take the file path — pure inputs only. | Caller (`AsyncPreviewImage.body.task`) reads cache state once and passes booleans; race with concurrent set is fine because the post-decision `await loadFullRes / Task.sleep / .set` already re-checks the cache. |
| `computeTargets` with zero-burst photos (no `burstGroupID`). | Same as today — `nextBurstsPhotos` collects through the unburst photos one by one; no special case needed. |

## Out of scope

- `ImageLoader` decode-path split or `decodeCore` consolidation.
- Any behavior change to skim/dwell thresholds, decode policy, or eviction.
- New L3 BDD tests (existing `PreviewCacheUITests` already covers the user-visible flow).
- Settings UI changes.
- `PreviewCache` further decomposition.

## Success criteria

- All three new test files (`ImageCacheTests`, `PreviewLoadPolicyTests`, `PrefetchCoordinatorTests`) pass via `xcodebuild test -scheme SuperPicky -destination 'platform=macOS' -only-testing:SuperPickyTests`.
- Existing test suite stays green.
- `xcodebuild build` succeeds (warnings-as-errors enforced per `d94cacb`).
- `swiftlint` clean (existing pre-commit gate).
- `apps/mac-client/SuperPickyApp/PreviewView.swift` LOC drops by roughly 115 (ImageCache extraction) + ~30 (policy extraction) ≈ 145 lines, reflecting the moved code.
- No git diff in `PreviewCache.swift`, `NavigationStateMonitor.swift`, `ImageLoader.swift` decode body, or any UI test file.

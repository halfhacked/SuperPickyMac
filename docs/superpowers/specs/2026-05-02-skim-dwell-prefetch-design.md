# Skim/Dwell Adaptive Prefetch — Design

## Context

PR #66 shipped a disk JPG cache, RAM working-set cache, and burst-aware prefetch. After it landed the foreground decode no longer stalls main and memory stays bounded, but two cold-path scenarios remain:

1. **Fast scrubbing in zoom mode.** The foreground decoder is serialised through `ImageDecodeQueue`; ARW decodes take ~250 ms, so the user's perceived rate caps at ~4/sec regardless of how fast they hit `→`. Holding `→` at 10/sec means 60% of intermediate keypresses are cancelled before they decode; the user sees a slideshow at decoder rate, not at input rate. Prefetch can't help — its serial queue runs at the same ~4/sec.
2. **Wasted prefetch CPU during skim.** The prefetch fires on every `selectedPhotoID` change, including during fast scrubbing where its results will never be reached before the user moves on. The work isn't lost (it lands in cache eventually), but the user pays for it via thermal/IO contention while they're still flying.

The user's mental model for the typical flow is **skim → dwell → skim → dwell**: skim a burst looking for the keepers, dwell on candidates to inspect them, skim to the next burst. The optimisation is to make prefetch and foreground decode policy match that cycle.

## Approach

Adopt **Approach A** from the brainstorm — adaptive resolution applies only to the skim mode, only in zoom view, with a state machine driving the prefetch fire timing.

- During skim, the foreground decoder uses the existing 2000 px preview path (~30 ms via the embedded ARW preview) instead of the full RAW (~250 ms). Up to ~30/sec input is achievable.
- During dwell, the foreground decoder upgrades in place to full-res (the existing dwell-preload mechanism extended to zoom mode), and `PrefetchCoordinator.update` fires for the new context. Decoded full-res images warm `ImageCache.fullRes`; their disk JPGs land in `~/Library/Caches/com.halfhacked.superpicky/preview/` via the existing write path.
- Single deliberate keypresses in zoom mode (no skim signal) keep their current behavior: full-res decode straight away, no soft-then-sharp flicker.

Approach B (universal preview-first with dwell upgrade for *every* photo) was rejected because it would flicker soft → sharp on every dwell, which is visually busier than the current single-keypress experience.

## State machine

`NavigationStateMonitor` (new) classifies user input timing into one of four states.

```
IDLE  ──(keypress)──> ACTIVE  ──(2nd press within 250ms)──> SKIM
  ▲                     │                                     │
  │                     │ (no press for 500ms)                │
  └─────────────────────┴─────────────(500ms idle)────────────┘
                                  │
                                  ▼
                                DWELL
```

| State | Trigger | Foreground decode | Prefetch fires? |
|---|---|---|---|
| `idle` | Initial / after `reset()` | Full-res (current) | No |
| `active` | Single `note()` | Full-res (current) | Pending dwell |
| `skim` | 2 notes within 250 ms | 2000 px preview (zoom only) / unchanged for fit | No |
| `dwell` | 500 ms idle after last note | Full-res, upgrade in place if currently soft | Yes — fires `onEnterDwell` |

Thresholds:
- **`skimThreshold = 250 ms`** — inter-keypress gap that promotes ACTIVE to SKIM. ~4/sec roughly matches the RAW-decode ceiling.
- **`dwellThreshold = 500 ms`** — silence that fires the dwell hook. Comfortable "I've stopped" pause; matches the codebase's existing 400 ms dwell-preload calibration within an order.

Both thresholds are constants today, tunable via `#if DEBUG` overrides if real-world usage suggests revising them.

## Components

| File | Status | Change |
|---|---|---|
| `apps/mac-client/SuperPickyApp/NavigationStateMonitor.swift` | new (~80 lines) | State machine, `note()`, `onEnterDwell` hook, `reset()`. `@MainActor`. |
| `apps/mac-client/SuperPickyApp/PrefetchCoordinator.swift` | edit | Hook `NavigationStateMonitor.shared.onEnterDwell` → `update(currentIndex:photos:)`. Stop firing on raw selection-change. |
| `apps/mac-client/SuperPickyApp/PreviewView.swift` | edit | At task start, branch only in zoom mode (`zoomState.scale > 1.0`): if `state == .skim`, take the 2000 px preview path; otherwise keep the current full-res path. Fit mode is unchanged (already adaptive: 2000 px preview, dwell-warm full-res). Observe state transitions and upgrade in place to full-res when state becomes `.dwell` while displaying preview-tier in zoom. |
| `apps/mac-client/SuperPickyApp/ContentView.swift` | edit | Replace direct `PrefetchCoordinator.shared.update(...)` call in `onChange(selectedPhotoID)` with `NavigationStateMonitor.shared.note(...)`. |
| `apps/mac-client/SuperPickyApp/AppState.swift` | edit | Call `NavigationStateMonitor.shared.reset()` next to the existing `PrefetchCoordinator.shared.reset()` on folder change. |

The disk JPG cache (`PreviewCache`), the RAM cache (`ImageCache.fullRes` / `ImageCache.preview`), the dwell-preload, the prefetch decode queue, and the cache-write queue all stay exactly as they are. We're rerouting *when* the existing pipelines fire, not changing what they do.

### Sketch — `NavigationStateMonitor`

```swift
@MainActor
final class NavigationStateMonitor {
    static let shared = NavigationStateMonitor()

    enum State: Sendable { case idle, active, skim, dwell }

    private(set) var state: State = .idle
    private var lastKeypressAt: Date?
    private var dwellTimer: Task<Void, Never>?
    private var pendingContext: (currentIndex: Int, photos: [Photo])?

    var onEnterDwell: ((Int, [Photo]) -> Void)?

    func note(currentIndex: Int, photos: [Photo]) {
        let now = Date()
        let gap = lastKeypressAt.map { now.timeIntervalSince($0) }
        lastKeypressAt = now
        pendingContext = (currentIndex, photos)
        state = (gap.map { $0 < skimThreshold } ?? false) ? .skim : .active
        scheduleDwellTimer()
    }

    func reset() { /* cancel timer, clear context, state = .idle */ }

    private func scheduleDwellTimer() { /* cancel + restart 500 ms timer */ }
    private func enterDwell() { /* state = .dwell; onEnterDwell?(...) */ }
}
```

## Data flow

### Single deliberate keypress in zoom mode (no skim)

```
t=0     User presses →
        ContentView.onChange → NavigationStateMonitor.note()
        State: idle → active
        SwiftUI rebinds photo → PreviewView.task → reads state .active → full-res path
t=250   Full-res decode completes → PreviewView shows sharp image
t=500   Dwell timer fires → State: active → dwell → onEnterDwell
        PrefetchCoordinator.update() warms same-burst + next-burst
```

### Fast skim through 30 photos in zoom mode

```
t=0     Press 1 → State: idle → active → full-res task starts
t=100   Press 2 (gap 100 ms < 250 ms) → State: active → skim
        Prior task cancelled by .task(id:) rebind
        New task → state .skim + zoom > 1.0 → 2000 px preview path → ~30 ms
t=200..t=2000   Each press repeats: ~30 ms decode, dwell timer keeps resetting
                No prefetch fires.
t=2000  User stops on photo 30
t=2500  Dwell timer fires → State: skim → dwell
        onEnterDwell → PrefetchCoordinator.update(centre = 30)
        PreviewView.onChange(state == .dwell) → upgrade in place to full-res
t=2750  Full-res of photo 30 lands → swap to sharp image
        Prefetch warms photo 30's burst + next burst
```

### Skim → dwell → skim → dwell (the typical cull cycle)

The classic culling rhythm. Prefetch fires once per dwell with the latest context; in-flight tasks from the prior dwell are diff'd against the new target set (existing anti-thrash logic).

### Folder open

`AppState.loadPhotos` calls `PrefetchCoordinator.prefill(photos:around:0)` directly — folder-open is treated as an immediate dwell so the initial RAM-cache fill starts before any user input. `NavigationStateMonitor.reset()` runs alongside.

## Edge cases & error handling

| Case | Behavior |
|---|---|
| Cancellation during dwell upgrade | User resumes skim mid-decode → `.task(id:)` rebind cancels the upgrade. The image stays soft until next dwell. No stale full-res lands on the wrong photo (existing photo-ID pinning in PreviewView handles this). |
| Stale `pendingContext` after filter change | Filter change shifts `selectedPhotoID`, which fires `onChange` → `note(...)` with the fresh photo list. Latest `note()` wins. Folder change calls `reset()` to invalidate. |
| Re-entry into skim while prefetch is in-flight | Serial `prefetchDecodeQueue` keeps decoding the in-flight target to completion — useful work; lands in cache + disk. New prefetches don't schedule (state is `.skim`). When user dwells again, the diff against the new target set cancels in-flight tasks not in the new set. |
| Decode failure | ImageLoader returns nil → PreviewView shows the placeholder bird icon. State machine doesn't care. |
| Single-photo folder | `note()` with 1 photo → idle → active → dwell → `update()` produces empty target set → no-op. Safe. |
| Wrong threshold | If 250 ms is too aggressive, deliberate ~3–4/sec pacing accidentally trips SKIM and shows soft images. Mitigated by `info`-level state-transition logs we can audit; thresholds are constants tunable in DEBUG. |
| Concurrency | Everything is `@MainActor` — `note()` runs from SwiftUI `.onChange`, `dwellTimer` is a MainActor `Task`, `onEnterDwell` callback runs MainActor, `PrefetchCoordinator.update` is MainActor. No cross-actor hops. |

## Testing

### L1 — `NavigationStateMonitorTests` (new, ~80 lines, Swift Testing)

Inject a clock so tests don't sleep on real time.

- `idleStartsIdle` — initial state is `.idle`.
- `singlePressEntersActiveThenDwell` — one `note(...)`, advance 500 ms → state is `.dwell`, `onEnterDwell` fired with captured context.
- `twoFastPressesEnterSkim` — `note()` at t=0, `note()` at t=200 ms → state is `.skim`.
- `skimDecaysToDwell` — once in `.skim`, no more presses for 500 ms → state becomes `.dwell`.
- `dwellTimerCancelledOnNewPress` — dwell timer pending, new press resets it.
- `resetReturnsToIdle` — `reset()` cancels timer, clears pending context, state back to `.idle`.
- `pendingContextIsLatestNote` — multiple `note()` calls; `onEnterDwell` fires with the most recent one.

### L1 — `PrefetchCoordinatorWiringTests` (new, small)

Verify the wiring: `PrefetchCoordinator.shared.update` runs when `NavigationStateMonitor.shared.onEnterDwell` fires, and not on raw `note()` calls. Spy on the prefetch coordinator.

### L3 — extend `PreviewCacheUITests`

`test03_skimSuppressesPrefetchUntilDwell`:

1. Open folder, wait for processing.
2. Press `z` to enter zoom.
3. `app.typeKey("→", ...)` 10 times rapidly — XCUITest delivers synchronously, gap < 100 ms.
4. Capture cache directory's file count immediately.
5. Wait 1 s for dwell.
6. Capture cache directory's file count again.
7. Assert post-dwell count > during-skim count.

The delta proves prefetch fires on dwell, not during skim. Doesn't try to assert transient soft-vs-sharp render — that's eyeballed in manual perf.

### Manual verification (release build)

- Hold `→` for 5 s in zoom mode on an ARW folder: photos should cycle visibly faster than ~4/sec. Each frame slightly soft is expected.
- Stop on a photo: it should sharpen within ~250 ms.
- Watch `log stream --predicate 'category == "NavigationState"'` for state transitions.
- `ImageCache.fullRes` should still cap at the configured budget; skim should add no new RAM-cache entries (no full-res decodes happened during skim).

## Out of scope

The remaining brainstorm angles are deferred:

- Burst-end aware "dump the bridge" prefetch.
- Fit-mode preview-tier prefetch (`ImageCache.preview` warming).
- Filter-change pre-emptive warming.
- Compare-mode dual-centre awareness.
- Pinning same-burst photos against eviction.
- Memory-pressure adaptation.
- Smart hydrate when disk JPG already exists.

Each can be pursued independently after this lands; none of them depend on each other or on this work being shipped.

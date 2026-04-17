# Streaming Pipeline Redesign — Plan

**Goal:** Fix the 30-second slow start on large folders by running the EXIF pre-pass in parallel with the ML loop, while preserving live burst grouping in the UI and guaranteeing no photo is lost when its burst neighbor arrives out of order.

**Context:** Real-world bench on `/Volumes/Birds 8T/Pictures/2025` (8,983 RAW files on USB drive) showed ~30 s dead time before ML starts. The current pipeline blocks at three sync steps before dispatching any ML work: EXIF pre-pass for every file, timestamp sort, and SpeciesFilter cache pre-warm. After the redesign, ML dispatches immediately in filesystem order and the sort+warm happen concurrently.

**Non-goals:** Not addressing the unidentified-bird root cause (threshold tuning is a separate issue, flagged for follow-up). Not addressing throughput degradation over long runs (external-drive I/O is the bottleneck; orthogonal). Not addressing UI unresponsiveness (suspect main-thread starvation from `@Observable` updates; separate debug needed).

---

## Constraints

Derived from the conversation:

| # | Constraint | Source |
|---|---|---|
| C1 | ML loop starts without waiting for the full EXIF pre-pass | "we can run ML in parall[el]" |
| C2 | Live burst grouping preserved — UI sees burst flags as they're discovered, not only at end | "we need live update" |
| C3 | No photo is lost from burst detection, even if it completes ML before its neighbor's timestamp is known | "some images that has already been through ML while the array is being built. Make sure these won't be lost" |
| C4 | Each reconcile compares against only the 1–2 closest neighbors in the sorted index, not the full time window | "only compare with the 1 or 2 who is the closest" |
| C5 | Burst time threshold is config-driven via `burstFps` (150 ms at 10 fps, 75 ms at 20 fps) — no new magic numbers | "should be controlled by the config" |
| C6 | No DB query per photo for burst reconciliation (would add a SELECT per photo) | "This new query will have perf penalty?" |
| C7 | Recursive directory scan (already landed in 17d2179) | "we need to scan recursively" |

---

## Architecture

### Before

```
scan → EXIF pre-pass (N files × 5-10ms / 12 cores ≈ 1-30s) → timestamp sort
     → SpeciesFilter pre-warm → ML loop (iterates timestamp-sorted)
     → finalize (incremental burst detect against lastPhoto) → picked flag
```

Blocks on each step before the next. On small folders (~877 files, local SSD) the prelude is ~1s and invisible. On 8,983 files on a USB drive it's ~30s of dead air.

### After

```
                ┌─ pre-pass Task.detached
scan → open DB ─┤  for each file: read EXIF, store timestamp into TimestampStore,
                │  collect GPS cells → fire SpeciesFilter pre-warm when done
                │
                └─ ML loop (iterates scannedFiles filesystem-order)
                     │
                     └─ finalize: write-behind { save + XMP + geocode }
                                   burst-reconcile Task chain (serial)
                                   └─ await TimestampStore.get(path)
                                       insert into sorted index
                                       check ≤2 closest neighbors
                                       emit DB updates + onPhotoProcessed
```

Three concurrent chains:
1. **Pre-pass Task** — reads EXIF for all files, fans writes into `TimestampStore`.
2. **ML loop + write-behind chain** — dispatches ML work, writes photo rows.
3. **Burst reconcile chain** — streams from finalize, gates on per-path timestamp, maintains in-memory sorted index.

### Key components

**`TimestampStore` (actor)** — Per-key async store. Pre-pass calls `set(path, timestamp)` as each file is read. Reconcile calls `await get(path)` which suspends via a continuation until the timestamp arrives (or `finish()` drains with nil for files with no EXIF). This is what satisfies C3 — a photo that finishes ML before its neighbor's timestamp lands will still see it when its reconcile step resolves.

**Burst reconciler chain (serial Task chain)** — Same pattern as the existing `writeBehindChain`. Each finalize appends one reconcile task to the chain. Chain is serial so the in-memory sorted index mutates race-free without an actor.

**In-memory sorted index** — `[Entry]` with binary-search insert. Entry has photoID, timestamp, pHash, burstGroupID, isBurstBest, burstScore (sharpness × 0.5 + aesthetics × 0.5). Captured by the reconcile chain's closures via a reference wrapper (class or shared state in `process()` scope).

**`ReportDatabase.updateBurstFlags(id:burstGroupID:isBurstBest:)`** — Partial SQL `UPDATE` so burst-flag updates don't clobber location/species columns via GRDB's REPLACE semantics. Used by the reconciler's flag-change tasks, queued into writeBehindChain (so they serialize behind the initial save for that photo).

### Reconcile algorithm (per photo)

```
1. Wait for this photo's timestamp via TimestampStore
2. If nil (no EXIF) → skip, no burst involvement
3. Binary-search insert into sorted index
4. Compare new entry to the 1-2 immediate neighbors (index-1, index+1):
   - Both outside threshold → photo is solo; if old neighbors had a group, unchanged
   - One or both within threshold:
     · Find the contiguous "burst window" (walk outward while adjacent gap ≤ threshold)
     · Recompute bestID within that window (max burstScore)
     · If window length ≥ minBurstCount: assign groupID (reuse existing if window already had one, else new UUID); mark bestID; emit updates for photos whose flags changed
     · If window length < minBurstCount: clear groupID/best for photos that were in a group
5. For each photo with changed flags:
   - writeBehind { db.updateBurstFlags(...) }
   - onPhotoProcessed(updatedPhoto) so UI refreshes
```

Only 1–2 neighbors are compared (satisfies C4); the burst window walk is bounded by actual burst size (typically 2–10), not the full time window.

### Edge cases

- **Photo with no EXIF timestamp** — reconcile sees `nil` from TimestampStore, returns early, photo stays solo with null burstGroupID. Consistent with today's behavior.
- **Two photos in different groups that a new photo bridges** — reconcile walks outward from the insertion point; if the walk spans both groups, merge them into one (pick the older groupID). Emit updates for every photo whose groupID changed.
- **Retroactive bestID change** — when a later-arriving photo has higher burstScore than the current best in its window, reconcile re-runs `selectBest` on the window and emits an update for the old best (now false) and the new best (now true).
- **Pre-pass still running when ML drains** — `await prePassTask.value` (or `timestampStore.finish()` once pre-pass completes). Any reconciles awaiting keys that never arrive (files the pre-pass couldn't read) get `nil` and short-circuit.
- **Write-behind ordering** — initial save for photo N is queued by finalize first; burst-flag updates for photo N are queued later by reconcile. Both go through `writeBehindChain` which is serial, so the save always lands before the flag update.
- **GRDB REPLACE vs UPDATE** — initial save uses REPLACE (sets all columns including null burst flags). Reconciler uses the new partial `updateBurstFlags` so it doesn't clobber location/species fields already saved.

---

## File Inventory

### New files

| File | Purpose |
|---|---|
| `SuperPickyApp/TimestampStore.swift` | `actor TimestampStore` — per-key async store with `set/finish/get` |
| `SuperPickyApp/BurstReconciler.swift` | `class BurstReconciler` — sorted-index insert + window walk + flag-change emission |
| `SuperPickyTests/Core/TimestampStoreTests.swift` | Unit tests: set-then-get, get-before-set (wait), finish drains waiters, multi-waiter same key |
| `SuperPickyTests/Core/BurstReconcilerTests.swift` | Unit tests: insert in order, insert out of order, new photo bridges two groups, retroactive bestID, solo photo stays nil, min-burst-count threshold |

### Changed files

| File | Change |
|---|---|
| `SuperPickyApp/PipelineCoordinator.swift` | Remove sync pre-pass; add `Task.detached { runPrePass }` that writes to `TimestampStore` and fires pre-warm. Remove incremental-burst block in `finalize`. Add burst reconcile queue. Add `MLWorkResult.gps`. Drop `preGPS` param from `processMLWork` (processOnePhoto extracts from imageProps). After ML drains, wait for pre-pass + reconcile chain. No post-hoc `runBurstDetection` call (reconciler is authoritative). |
| `SuperPickyApp/ReportDatabase.swift` | Add `updateBurstFlags(id:burstGroupID:isBurstBest:)` — partial SQL UPDATE. |
| `SuperPickyTests/Core/PipelineCoordinatorTests.swift` | Update the 3 tests that exercise burst paths; none assert incremental burst timing today, so change should be minor. |

### Removed

| Code | Why |
|---|---|
| `runBurstDetection` call site at end of `process()` | Reconciler is now authoritative; no batch pass needed. |
| Incremental burst block in `finalize` (lines ~229-292 of current PipelineCoordinator) | Replaced by reconcile chain. |
| `timestampByPath`/`gpsByPath`/`uniqueCells` built inline in `process()` | Moved into `runPrePass`. |

---

## Task List

Numbered, each landing as one commit.

- [ ] **1. `TimestampStore` + tests.** Add the actor + 4 unit tests. Build + tests green. No pipeline changes yet.
- [ ] **2. `ReportDatabase.updateBurstFlags` + tests.** Partial UPDATE path; test that it leaves location/species columns untouched.
- [ ] **3. `BurstReconciler` + tests.** New class. Unit tests against the 6 scenarios listed under "Edge cases": in-order, out-of-order, bridge, retroactive best, solo, below-min-count. No pipeline wiring yet.
- [ ] **4. Pipeline wiring.** Rewrite `PipelineCoordinator.process()` per the architecture above. Remove the sync pre-pass, start `prePassTask`, replace the incremental-burst block with reconcile queuing, drop the post-hoc `runBurstDetection` call. Change `MLWorkResult` to carry GPS. Update mocks in tests. All 285 existing tests still pass.
- [ ] **5. Bench local.** Run `scripts/bench-real-photos.sh ~/photo` — confirm total ≈ 29 s (no regression vs current baseline). Confirm `pipeline.finished` log shows pre-pass overlapping with ML.
- [ ] **6. Bench external drive.** Re-run `/Volumes/Birds 8T/Pictures/2025`. Target: first DB row within <3 s of launch (vs 30+ s today). Compare total wall time.
- [ ] **7. Commit + push.**

---

## Test Strategy

For each new component, unit tests with deterministic fixtures — no test images, no CoreML, no network.

**TimestampStore**
1. `set_then_get_returns_value` — store a timestamp, `await get` returns it immediately.
2. `get_before_set_waits` — spawn a Task calling `await get`, assert it hasn't resumed; `set`; assert it resumes with the value.
3. `finish_drains_waiters_with_nil` — call `get` in a Task, call `finish`, assert `get` resumes with nil.
4. `set_to_nil_resolves_waiters` — if pre-pass reads a file but gets `nil` timestamp, waiters resume with nil.

**ReportDatabase.updateBurstFlags**
1. `updates_only_burst_columns` — save a photo with locationCity/speciesName set; call updateBurstFlags; fetch and assert those columns still set, burst columns changed.
2. `accepts_nil_group_to_clear` — call with `burstGroupID: nil, isBurstBest: false`; fetch and assert cleared.

**BurstReconciler**
1. `insert_in_order_forms_burst` — insert A@0, B@100ms, C@200ms; assert all three get same groupID, best is whoever has highest burstScore.
2. `insert_out_of_order_same_result` — insert B, A, C; final state identical to #1.
3. `photo_bridges_two_groups` — start with [A@0, B@100ms] (group G1) and [D@400ms, E@500ms] (group G2) separated by 300ms; insert C@250ms; depending on thresholds: if C within threshold of both B and D, merge → all five in one group. Otherwise two separate groups.
4. `retroactive_best_change` — insert A@0, B@100ms (B has higher score → B is best). Insert C@50ms with higher score than B → C becomes best, B's flag change emitted.
5. `solo_stays_nil` — insert A, then B 10s later → both solo, groupID nil, no changes emitted after insert.
6. `below_min_count_stays_solo` — with minBurstCount=3, insert just A+B within threshold → groupID stays nil.

**Pipeline integration (existing tests)**
- `PipelineCoordinatorTests.birdDetectedRatesCorrectly` etc. continue to pass. Burst-related tests (currently 0? — audit needed) get adjusted if they assert timing of burst-flag visibility.
- Add a new `PipelineLiveBurstTests` that processes 3 photos within 100ms of each other using fake timestamps and a mock inference client; asserts that `onPhotoProcessed` is called ≥2 times for the photos whose burst flags change (initial save + burst update).

---

## Perf Expectations

| Metric | Current (large folder) | Target |
|---|---|---|
| Time to first DB row | ~30 s (pre-pass blocks) | < 3 s (scan + DB open only) |
| ML total wall time | Unchanged | Unchanged or slightly lower (no pre-pass stall on first ML batch) |
| Burst reconcile overhead | Embedded in finalize, ~μs/photo | Same (binary search + 1–2 compares per photo, via serial chain) |
| Pre-pass wall time | ~6 s (parallel EXIF reads) | Same; hidden behind ML now |
| Write-behind tail | ~0 s today | Add the burst-reconciler-drain time at end — expected < 1 s since each reconcile is cheap |

On small folders (~877 files, local SSD), total wall time should be unchanged from the current 29 s baseline; the pre-pass is already fast enough to be invisible.

---

## Risk Register

- **R1: Burst reconciler state corruption under concurrency.** Mitigated by making the reconcile chain serial (same pattern as writeBehindChain) — only one reconcile executes at a time.
- **R2: Write ordering (initial save races reconcile flag-update).** Mitigated by routing flag updates through writeBehindChain so they land after the initial save.
- **R3: `TimestampStore` leaks continuations.** Mitigated by `finish()` draining all waiters; called unconditionally at the end of `runPrePass`.
- **R4: Photos with no EXIF timestamp block their reconcile forever.** Mitigated by `finish()` + `get` returning nil; tests cover this case.
- **R5: Perf regression on small folders.** The actor-hop per get-with-wait is ~μs. No regression expected. Verified in step 5.
- **R6: SpeciesFilter pre-warm fires too late.** On external drives, pre-pass takes ~6s. First 6 ML photos may hit the cold SQLite mutex for ~1-2s. Acceptable — no worse than a run without pre-warm.

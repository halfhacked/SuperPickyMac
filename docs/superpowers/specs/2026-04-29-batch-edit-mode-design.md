# Batch Edit Mode — Design

**Status:** Approved
**Date:** 2026-04-29
**Scope:** Add multi-select to the filmstrip and route the existing edit
operations (pick, rate/reject, species) through a unified set-based API.

## Goal

Let the user shift/cmd-click in the filmstrip to select multiple photos, then:

1. Batch edit species (set primary / add / remove) using the existing species
   edit panel as a "virtual photo" view of the selection.
2. Batch pick / unpick.
3. As a free side-effect: batch rate (digit keys) and batch reject (`x`),
   since the unified API treats single-photo ops as 1-element batches.

Out of scope:

- Multi-select in the sidebar buckets (filmstrip only).
- A new grid view.
- Batch delete (destructive multi-trash semantics warrant their own flow).
- Multi-select in `CompareView` and `FullscreenViewer` — they remain
  single-active-photo surfaces.

## Selection model

`PhotoSelection` (new file, `apps/mac-client/SuperPickyApp/PhotoSelection.swift`)
is an `@Observable` final class composed into `AppState`:

```swift
@Observable
final class PhotoSelection {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var activeID: UUID? = nil      // most-recently clicked, shown in preview
    private(set) var anchorID: UUID? = nil      // for shift-click range

    var count: Int { selectedIDs.count }
    var isMulti: Bool { selectedIDs.count > 1 }
    func contains(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    // Click handlers (caller passes the ordered photo list — needed for range)
    func click(_ id: UUID, photos: [Photo])
    func shiftClick(_ id: UUID, photos: [Photo])
    func cmdClick(_ id: UUID, photos: [Photo])

    // Keyboard
    func arrow(direction: Int, photos: [Photo])           // collapse + move
    func shiftArrow(direction: Int, photos: [Photo])      // extend
    func selectAll(photos: [Photo])
    func collapseToActive()

    // Lifecycle
    func clear()
    func reconcile(with photos: [Photo])  // drop IDs no longer in filtered list
}
```

Pure helpers live in a sibling `enum PhotoSelectionEditor` (range, toggle,
range-from-anchor, reconcile), so the click/keyboard methods stay thin and
the math is unit-testable without `@Observable` state.

### Invariants

- `activeID == nil` ⟺ `selectedIDs.isEmpty`
- `activeID != nil` ⟹ `selectedIDs.contains(activeID!)`
- `anchorID` is set on plain click and cmd-click; preserved on shift-click;
  cleared together with `selectedIDs` on `clear()`.

### Composition into `AppState`

`AppState` gains `let selection = PhotoSelection()`. The existing
`selectedPhotoID` becomes a back-compat passthrough to `selection.activeID`
so the rest of the app (compare, fullscreen, info panel, threshold calibrator)
keeps working without per-call-site rewrites.

`applyFilter()` and `loadPhotos()` call `selection.reconcile(with: photos)`
so filter and folder changes drop stale IDs. If the active photo is filtered
out, `activeID` falls back to the first remaining selected photo, then to
`photos.first?.id`, then nil. Folder switch (different folder) calls
`selection.clear()`. `clearPhotos()` calls `selection.clear()`.

## Filmstrip interaction & visuals

`ThumbnailStripView` takes the `PhotoSelection` instead of just a
`Binding<UUID?>`:

```swift
struct ThumbnailStripView: View {
    let photos: [Photo]
    @Bindable var selection: PhotoSelection
    ...
}
```

### Click dispatch

SwiftUI's `.onTapGesture` cannot read `NSEvent.modifierFlags` on click.
The strip mounts a single `MouseClickRedirector` (`NSViewRepresentable`,
same shape as the existing `ScrollWheelRedirector`) that installs an
`NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown)`. On left-mouse-
down inside the strip's bounds it reads modifier flags, hit-tests to find
which thumbnail was clicked, and dispatches one of
`selection.click/shiftClick/cmdClick(id, photos:)`. The existing
`.onTapGesture { selectedPhotoID = photo.id }` is removed — the NSEvent
monitor is the single source of truth for clicks.

### Visual states

`ThumbnailCell` renders a 3-state border:

| State | Border |
|-------|--------|
| Active (most-recently clicked, in `selectedIDs`) | Accent color, 2pt — current behavior |
| Also-selected (in `selectedIDs` but not active) | Accent color, 2pt, **0.5 opacity** |
| Pick-only (not selected) | Orange, 2pt @ 0.6 opacity — current behavior |
| Plain | Clear |

Active wins over also-selected wins over pick. Burst-dimming logic is
unchanged — it still keys off the active photo's `burstGroupID`.

Cells gain `accessibilityValue` reflecting `selected | active | none`
so XCUITests can assert visual state.

### Selection counter

The existing `PhotoCounter` line ("47 of 200") gains a leading
"**N selected** · " when `selection.isMulti`. No new toolbar surface.

## Keyboard

| Key | Today | New |
|-----|-------|-----|
| `←` / `→` | move selection | collapse to single (active) and move |
| `shift+←` / `shift+→` | (none) | extend selection by one in arrow direction |
| `⌘A` | (none — only digit filters) | select all in `filteredPhotos` |
| `esc` | exits fullscreen | exits fullscreen if open, else collapse to active |
| `p` | toggle pick on active, auto-advance | A-semantics batch toggle (below); auto-advance suppressed when `isMulti` |
| `x` | reject active, advance | reject all selected; auto-advance suppressed when `isMulti` |
| `0`–`5` | rate active, auto-advance | rate all selected; auto-advance suppressed when `isMulti` |
| `⌘Z` | undo last action | undoes last action — including a batch as one step |

`⌘0`–`⌘5` (set minimum-stars filter) is unchanged. Single-photo digit and
`p` keys keep auto-advance when `selection.count == 1`.

### Active-photo coupling

Everything that previously read `appState.selectedPhotoID` reads
`appState.selection.activeID` (via the back-compat passthrough). `PreviewView`,
`ExifPanelView`, `ThresholdCalibratorView`, `CompareView`, `FullscreenViewer`
keep showing the active photo. Compare and fullscreen do not enter "batch
mode" — they always operate on the active photo as today.

### Filter and folder lifecycle

When the user changes sidebar selection (rating/picks/species/etc.),
`AppState.applyFilter()` calls `selection.reconcile(with: photos)`, which
keeps any IDs still in the new filtered list and drops the rest. This
preserves multi-selections through filter swaps when the photos overlap.

Folder change clears the selection entirely.

## Unified mutation methods on `AppState`

Single-photo and batch collapse into one method per operation. Selection size
is just "how many IDs are in the set." A solo edit is a 1-element set.

```swift
// Pick — A-semantics: if any in `ids` is unpicked → pick all; else unpick all.
// Explicit-only — no burst fan-out (matches today's per-photo pick).
func setPick(ids: Set<UUID>)

// Rate (used by digit keys; reject calls this with rating: 0).
func setRating(ids: Set<UUID>, rating: Int, manual: Bool = true)

// Reject = setRating(rating: 0) + remove from filtered `photos` array.
func reject(ids: Set<UUID>)

// Inline rename of primary species. Burst-fans-out per id.
func correctSpecies(ids: Set<UUID>, commonName: String)

// Set primary species across `ids`. If a target photo doesn't already have
// this species, ADD it and make primary; else promote it.
// Burst-fans-out per id.
func setPrimarySpecies(ids: Set<UUID>, species: SpeciesMatch)

// Add to every photo that doesn't already have it. Burst-fans-out per id.
func addSpecies(ids: Set<UUID>, species: SpeciesMatch)

// Remove from every photo that has it. Burst-fans-out per id.
func removeSpecies(ids: Set<UUID>, species: SpeciesMatch)
```

The previous single-arg methods (`togglePick`, `ratePhoto`, `rejectPhoto`,
`setAssignedSpecies`, single-arg `correctSpecies`) are removed. Call sites
pass `selection.selectedIDs` (or `[id]` for code paths that haven't yet
been wired through selection). No "single vs. batch" branching anywhere.

`deletePhoto(id:)` stays single-photo. Batch delete is out of scope.

### Burst fan-out

Pick / rate / reject: explicit-only — applies to exactly `ids`.

Species methods (`correctSpecies`, `setPrimarySpecies`, `addSpecies`,
`removeSpecies`): each method computes its effective target set as
`ids ∪ ⋃(burstMemberIDs(for: id) for id in ids)` at write time, using
the current `allPhotos` (not a stale snapshot). This honors the existing
"per-photo attribute edit fans out to whole burst" rule.

### Unified undo

`UndoAction` becomes one shape regardless of operation count:

```swift
struct UndoAction {
    struct Entry {
        let photoID: UUID
        let previousRating: Int
        let previousIsPick: Bool
        let previousIsManualRating: Bool
        let previousAssignedSpecies: [SpeciesMatch]
        let wasHidden: Bool
    }
    let entries: [Entry]
}
```

Each method captures a full per-photo snapshot of previously-mutated state
for every affected photo (including burst fan-out targets), pushes **one**
`UndoAction`, and `⌘Z` reverts the whole set. Solo edits push a 1-entry
action and undo identically to today.

`maxUndoDepth = 20` unchanged.

### Pre-existing-bug fix

Today's `UndoAction` does not capture `previousAssignedSpecies`, so species
edits aren't undoable. The unified shape adds the field and reverses
species changes on `⌘Z`. This is an additive correctness improvement,
not a behavior break.

## Species edit panel (batch UI)

`SpeciesEditPanelView` (inside `ExifPanelView`) currently takes one `Photo`
and renders three sections: assigned, candidates, search. It now takes the
active photo plus the full selection set, and switches its data source by
selection size — same view shape, different inputs. The "virtual photo"
mental model: the panel shows the union of state across selected photos
and operations apply to the whole set.

### Header

When `selection.isMulti`: header reads `"Editing N photos"` (localized).
Otherwise unchanged single-photo filename.

### Assigned section

- **Single (count = 1):** unchanged — shows `assignedSpecies` in current
  order; primary on top; X removes; "Make primary" promotes.
- **Batch:** shows the **union** of `assignedSpecies` across the selection,
  ordered by (photos-having-it desc, then localized name asc). Each row
  optionally shows a small `n / N` badge if the species isn't on every
  selected photo. X → `removeSpecies(ids:species:)`. "Make primary" →
  `setPrimarySpecies(ids:species:)`.

### Candidates section

- **Single:** unchanged — shows the photo's stored top-K from
  `speciesTop5JSON`.
- **Batch:** shows the **union** of every selected photo's candidates,
  deduped by `speciesID`, ranked by **max confidence across the selection**,
  capped at top 10. Tap a candidate → `addSpecies(ids:species:)`.

### Search field

Behavior unchanged. Submitting a typed match calls
`addSpecies(ids:species:)` with the current selection.

### Aggregator helper

A new pure helper, sibling to `SpeciesAssignmentEditor`:

```swift
enum BatchSpeciesAggregator {
    static func unionAssigned(_ photos: [Photo]) -> [(SpeciesMatch, photoCount: Int)]
    static func topCandidates(_ photos: [Photo], limit: Int = 10) -> [SpeciesMatch]
}
```

Pure, testable in isolation, no DB, no `@Observable`.

### InfoBar inline rename

`InfoBarView` (under the photo, separate from the side panel): the inline
species rename field, when `selection.isMulti`, calls
`correctSpecies(ids:commonName:)` with the full selection. The displayed
species text shows the active photo's primary, with a small "(N selected)"
suffix when multi.

## Edge cases

**Race against ingest.** Batch ops can land while `PhotoIngestBatcher` is
still appending. Each method iterates a snapshot copy of `ids` and looks up
each photo via `allPhotoIndex` at write time; missing photos are skipped.
The undo entry only records photos that were actually mutated.

**Filter changes mid-edit.** Batch ops run synchronously on `@MainActor`;
`applyFilter()` cannot interleave. No drift between selection and the
photos array during a single op.

**Folder switch with edits in flight.** `cancelProcessing` and `loadPhotos`
already serialize on the main actor. `clearPhotos()` adds `selection.clear()`;
the undo stack is also cleared (matches today's `loadPhotos` behavior).

**Empty selection.** All batch methods early-return on `ids.isEmpty`.
Keyboard handlers no-op cleanly when nothing is selected.

**Selection survives processing.** `loadPhotos` is called repeatedly during
processing. Surviving IDs stay selected via `selection.reconcile(with: photos)`;
missing ones drop; active falls back per the invariants.

**Burst membership churn.** Burst groups can flip on the post-run
`loadPhotos` rebuild. Selection is keyed by `photo.id` (not burst), so it's
stable across burst churn. Burst fan-out is computed at edit time from
`allPhotos`, so a species edit always fans out to the current burst
membership.

**`reject` of multi-selection.** `reject` removes photos from filtered
`photos`. After a multi-reject, `selection.reconcile(with: photos)` drops
the rejected IDs; `activeID` falls back per the invariants. Auto-advance
on single-photo reject is preserved; suppressed when `isMulti`.

**XMP / DB write failures.** Per-photo writes already swallow errors and
log via the existing `mutatePhoto` pattern. Batch methods preserve
fail-quiet behavior — out of scope to aggregate errors into a sheet.

**Compare / Fullscreen with multi-selection.** Both operate on `activeID`
only. `c` opens compare on active + neighbor in `filteredPhotos`. `f` opens
fullscreen on active. Multi-selection is preserved while either is open and
remains active when they close.

**Sidebar bucket selection.** Shift/cmd-click in the sidebar is a no-op —
sidebar still toggles a single bucket.

## Tests

Three layers, matching `pre-commit.sh` and L3.

### L1 unit (`SuperPickyTests`)

Pure-helper tests, no `@Observable`, no DB, no UI:

- `PhotoSelectionEditorTests` — range computation (forward, backward,
  anchor swap), toggle add/remove, select-all on filtered list, reconcile
  drops stale IDs, anchor preserved across shift-click, anchor reset on
  plain click and cmd-click.
- `PhotoSelectionTests` — the `@Observable` wrapper's invariants:
  `activeID == nil ⟺ selectedIDs.isEmpty`; `activeID ∈ selectedIDs`;
  fallback when active is filtered out (first remaining selected → first
  photo → nil).
- `BatchSpeciesAggregatorTests` — union-with-counts (5/5, 3/5, 1/5);
  top-10 candidates by max confidence; dedup by `speciesID`; deterministic
  tie-break by name.
- `AppStateBatchMutationTests` (using a temp `.report.db`):
  - `setPick(ids:)` A-semantics across mixed / all-picked / all-unpicked
    sets (1, 2, 5 photos).
  - `setRating(ids:rating:)` writes DB + XMP for every id; one undo entry.
  - `setPrimarySpecies(ids:species:)` adds to photos missing the species,
    promotes on photos that have it; burst fan-out covers non-selected
    burst members.
  - `addSpecies` / `removeSpecies` no-op idempotence (re-add of an existing
    species, remove of an absent species).
  - One-undo-step: after a 5-photo batch op, `undoLastAction()` restores
    all 5 photos in a single call.
  - Pre-existing-bug fix: species edit + `undoLastAction` reverts species
    (with the new `previousAssignedSpecies` field).

### L3 BDD (`SuperPickyUITests` — XCUITest, on-CI only)

Per the BDD-required rule, every new feature gets L3 coverage, grouped
into existing classes where possible. New file or extension of an existing
strip-driving class:

- `BatchSelectionUITests`:
  - **Shift-click range:** click photo 1, shift-click photo 5 → 5 thumbnails
    carry the `selected` accessibility value; counter reads "5 selected".
  - **Cmd-click toggle:** click photo 1, cmd-click photo 3, cmd-click
    photo 3 again → ends with `{1, 3}` then `{1}`.
  - **`⌘A`** → all visible thumbnails carry `selected`; counter matches
    filtered count.
  - **`esc`** → collapse to single (active).
  - **Batch pick (`p`):** select 3, press `p`; verify all 3 carry pick flag
    and the on-disk XMP sidecars (`Subject` keyword) reflect pick state.
  - **Batch unpick:** `p` again on the same 3 → all unpicked.
  - **Batch rate (`3`):** select 3, press `3`; verify in-app star value
    and XMP `Rating` on disk.
  - **Batch species via panel:** select 3, open `i`, search & pick a species,
    click "Set as primary"; verify XMP `Subject` for all 3 lists the species
    + burst fan-out into non-selected burst members.
  - **One-step undo:** after any batch op, `⌘Z` restores all affected
    photos in a single press; in-app counters and XMP all match pre-op state.
  - **Filter change preserves overlap:** select 3 in "Folder" view, switch
    sidebar to "Picks" — selection reconciles to picked subset; switch back —
    surviving IDs are still selected.
  - **Folder change clears selection.**

Test fixtures: reuse existing
`apps/mac-client/SuperPickyUITests/test-photos/`. All assertions on
`waitForExistence` use `XCTAssertTrue(...)` per the silent-timeout rule;
any thumbnail past the viewport is reached via `arrowStripUntil` per the
LazyHStack rule.

### L1/L3 not added for

- Compare and Fullscreen viewers — single-photo behavior unchanged. Smoke
  that they still open from a multi-selection (using the active photo) is
  asserted in one existing test.
- Inline rename multi-target case — covered by the panel test's XMP
  read-back.

## File-level changes

New files:

- `apps/mac-client/SuperPickyApp/PhotoSelection.swift` — `@Observable`
  selection model + `enum PhotoSelectionEditor` pure helpers.
- `apps/mac-client/SuperPickyApp/BatchSpeciesAggregator.swift` — pure
  union/top-candidates aggregator.
- `apps/mac-client/SuperPickyApp/MouseClickRedirector.swift` —
  `NSViewRepresentable` for modifier-aware clicks in the strip.
- `apps/mac-client/SuperPickyTests/PhotoSelectionEditorTests.swift`
- `apps/mac-client/SuperPickyTests/PhotoSelectionTests.swift`
- `apps/mac-client/SuperPickyTests/BatchSpeciesAggregatorTests.swift`
- `apps/mac-client/SuperPickyTests/AppStateBatchMutationTests.swift`
- `apps/mac-client/SuperPickyUITests/BatchSelectionUITests.swift`

Modified:

- `AppState.swift` — composes `PhotoSelection`; replaces single-arg
  mutation methods with set-based ones; new unified `UndoAction` with
  `Entry[]`; `applyFilter` / `loadPhotos` / `clearPhotos` reconcile or
  clear selection.
- `ThumbnailStripView.swift` — accepts `@Bindable PhotoSelection`; mounts
  `MouseClickRedirector`; `ThumbnailCell` renders 3-state border and
  per-state `accessibilityValue`.
- `ContentView.swift` — `handleKey` rewires `p` / `0`–`5` / `x` /
  `⌘Z` / arrow / `shift+arrow` / `⌘A` / `esc` to selection-aware
  paths; `PhotoCounter` shows "N selected · " when `isMulti`.
- `ExifPanelView.swift` / `SpeciesEditPanelView` — header switches by
  count; assigned + candidates pull from `BatchSpeciesAggregator` when
  multi; action callbacks call set-based mutation methods.
- `MainView.swift` — wire callbacks to set-based methods (selection set
  + species args).
- `KeyboardHelpView.swift` — document new shortcuts (`shift+arrow`,
  `⌘A`, batch semantics for `p` / `0`–`5` / `x`).
- `A11y.swift` (UI test target) — new identifiers / values for selected
  vs. active states.
- `SuperPicky.xcodeproj/project.pbxproj` — register the new source files
  per the project's manual-pbxproj rule.

## Open follow-ups (out of scope for this change)

- Batch delete (multi-trash with confirmation flow).
- Multi-select in sidebar buckets ("select all photos of species X").
- Aggregate error reporting for partial XMP/DB write failures.
- Multi-photo Compare grid (>2-up).

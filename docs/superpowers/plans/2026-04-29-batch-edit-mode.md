# Batch Edit Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multi-select to the filmstrip and route every photo-mutating
operation (pick, rate/reject, species) through a unified set-based API
on `AppState`, so a 1-photo edit and an N-photo edit share a single code path.

**Architecture:** New `@Observable PhotoSelection` model owns selectedIDs +
activeID + anchor; pure helpers in `PhotoSelectionEditor` enum handle range /
toggle / reconcile math; `AppState` composes `PhotoSelection` and replaces its
single-arg mutation methods with set-based ones. `ThumbnailStripView` gets a
modifier-aware NSEvent click redirector and a 3-state cell border. The
existing species edit panel branches its data source by selection size,
sourcing union/aggregation from a new `BatchSpeciesAggregator` pure helper.

**Tech Stack:** Swift / SwiftUI / `@Observable`, GRDB (`ReportDatabase`),
Swift Testing (`@Suite` / `@Test`) for L1, XCUITest for L3.

**Reference spec:** `docs/superpowers/specs/2026-04-29-batch-edit-mode-design.md`

---

## File Structure

**New source files** (`apps/mac-client/SuperPickyApp/`):

| File | Responsibility |
|------|---------------|
| `PhotoSelection.swift` | `enum PhotoSelectionEditor` (pure helpers) + `@Observable final class PhotoSelection` |
| `BatchSpeciesAggregator.swift` | `enum BatchSpeciesAggregator` — pure union & top-N candidates |
| `MouseClickRedirector.swift` | `NSViewRepresentable` left-mouse-down monitor that reports `(point, modifierFlags)` |

**New test files:**

| File | Target |
|------|--------|
| `apps/mac-client/SuperPickyTests/Core/PhotoSelectionEditorTests.swift` | L1 |
| `apps/mac-client/SuperPickyTests/Core/PhotoSelectionTests.swift` | L1 |
| `apps/mac-client/SuperPickyTests/Core/BatchSpeciesAggregatorTests.swift` | L1 |
| `apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift` | L1 (DB-backed) |
| `apps/mac-client/SuperPickyUITests/BatchSelectionUITests.swift` | L3 (XCUITest, CI only) |

**Modified files:**

- `AppState.swift` — composes `PhotoSelection`; replaces `togglePick`/`ratePhoto`/`rejectPhoto`/`setAssignedSpecies`/`correctSpecies` with set-based methods; new unified `UndoAction` shape with `entries: [Entry]`; `applyFilter` / `loadPhotos` / `clearPhotos` reconcile or clear selection
- `ThumbnailStripView.swift` — accepts `@Bindable PhotoSelection`; mounts `MouseClickRedirector`; 3-state border + `accessibilityValue`
- `ContentView.swift` — `handleKey` rewires `p` / `0`–`5` / `x` / `⌘Z` / arrow / `shift+arrow` / `⌘A` / `esc` to selection-aware paths; counter shows "N selected · " when multi
- `ExifPanelView.swift` (and the embedded `SpeciesEditPanelView`) — header switches by count; assigned + candidates pull from `BatchSpeciesAggregator` when multi; action callbacks use set-based methods
- `MainView.swift` — wire callbacks to set-based methods
- `KeyboardHelpView.swift` — document new shortcuts
- `SuperPickyUITests/A11y.swift` — new identifiers / values for selected-vs-active states
- `SuperPicky.xcodeproj/project.pbxproj` — register every new `.swift` file (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase) per the project's manual-pbxproj rule

---

## Conventions referenced by every task

- **Build/test commands** (per `CLAUDE.md`):

  ```bash
  cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
  cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' -only-testing:SuperPickyTests
  cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' -only-testing:SuperPickyTests/<SuiteName>
  ```

  L3 (XCUITest) **does not run locally**; CI runs it. Per memory: don't run
  XCUITest suites locally — they hijack the mouse/keyboard.

- **Stale-binary precaution**: `touch` any file just edited, or delete
  `Build/Intermediates.noindex/SuperPicky.build/` before rebuilding when
  results look impossible.

- **Adding a new `.swift` file requires `pbxproj` registration** — every
  task that creates a new file includes a `pbxproj` step. Use a small
  Python/Ruby helper or hand-edit (the four-section pattern is: PBXBuildFile,
  PBXFileReference, the parent PBXGroup `children` array, the
  PBXSourcesBuildPhase `files` array). Reference an existing file's UUIDs as
  templates.

- **Swift Testing** (not XCTest) is the convention for new L1 tests:

  ```swift
  import Testing
  @testable import SuperPicky

  @Suite struct MySuite {
      @Test func behavesAsExpected() { #expect(actual == expected) }
  }
  ```

- **Commit style**: `feat:` / `refactor:` / `test:` prefixes, sentence-case
  subject, body wrapped at ~72 chars. Match recent commits like
  `fix(strip): 4-sided selection border renders (real fix for #48)`.

---

## Task 1: Pure selection helpers (`PhotoSelectionEditor`)

**Files:**
- Create: `apps/mac-client/SuperPickyApp/PhotoSelection.swift`
- Test: `apps/mac-client/SuperPickyTests/Core/PhotoSelectionEditorTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `apps/mac-client/SuperPickyTests/Core/PhotoSelectionEditorTests.swift`:

```swift
import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoSelectionEditorTests {

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    // MARK: - rangeIDs

    @Test func rangeIDsForwardIncludesEndpoints() {
        let xs = ids(5)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[1], to: xs[3], in: xs)
        #expect(r == [xs[1], xs[2], xs[3]])
    }

    @Test func rangeIDsBackwardSwapsEndpoints() {
        let xs = ids(5)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[3], to: xs[1], in: xs)
        #expect(r == [xs[1], xs[2], xs[3]])
    }

    @Test func rangeIDsSameAnchorReturnsSingle() {
        let xs = ids(3)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[1], to: xs[1], in: xs)
        #expect(r == [xs[1]])
    }

    @Test func rangeIDsMissingAnchorReturnsEmpty() {
        let xs = ids(3)
        let foreign = UUID()
        let r = PhotoSelectionEditor.rangeIDs(from: foreign, to: xs[1], in: xs)
        #expect(r.isEmpty)
    }

    // MARK: - toggling

    @Test func toggleAddsWhenAbsent() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0]]
        PhotoSelectionEditor.toggle(xs[1], in: &set)
        #expect(set == [xs[0], xs[1]])
    }

    @Test func toggleRemovesWhenPresent() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0], xs[1]]
        PhotoSelectionEditor.toggle(xs[1], in: &set)
        #expect(set == [xs[0]])
    }

    // MARK: - reconcile

    @Test func reconcileKeepsSurvivingIDs() {
        let xs = ids(4)
        var set: Set<UUID> = [xs[0], xs[1], xs[3]]
        PhotoSelectionEditor.reconcile(set: &set, against: [xs[0], xs[2], xs[3]])
        #expect(set == [xs[0], xs[3]])
    }

    @Test func reconcileEmptiesIfNoOverlap() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0], xs[1]]
        PhotoSelectionEditor.reconcile(set: &set, against: ids(2))
        #expect(set.isEmpty)
    }

    // MARK: - neighbor

    @Test func neighborForwardWrapsToLastWhenIndexInvalid() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: nil, direction: 1, in: xs)
        #expect(n == xs.first)
    }

    @Test func neighborForwardClampsAtEnd() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: xs[2], direction: 1, in: xs)
        #expect(n == xs[2])
    }

    @Test func neighborBackwardClampsAtStart() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: xs[0], direction: -1, in: xs)
        #expect(n == xs[0])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/PhotoSelectionEditorTests
```

Expected: FAIL with "cannot find 'PhotoSelectionEditor' in scope".

- [ ] **Step 3: Implement `PhotoSelectionEditor`**

Create `apps/mac-client/SuperPickyApp/PhotoSelection.swift`:

```swift
import Foundation

/// Pure list-mutation helpers for `PhotoSelection`. No `@Observable` state,
/// no SwiftUI, no DB — keeps the range / toggle / reconcile math
/// unit-testable in isolation. Matches the pattern of
/// `SpeciesAssignmentEditor`.
enum PhotoSelectionEditor {

    /// Inclusive range of photo IDs from `anchor` to `target` in `photos`
    /// list order. Returns `[]` if either ID is missing from `photos`.
    /// Endpoint order is normalized — backward ranges work the same as
    /// forward.
    static func rangeIDs(from anchor: UUID, to target: UUID, in photos: [Photo]) -> [UUID] {
        guard
            let i = photos.firstIndex(where: { $0.id == anchor }),
            let j = photos.firstIndex(where: { $0.id == target })
        else { return [] }
        let lo = min(i, j), hi = max(i, j)
        return photos[lo...hi].map(\.id)
    }

    /// Add `id` to `set` if absent, remove it if present.
    static func toggle(_ id: UUID, in set: inout Set<UUID>) {
        if !set.insert(id).inserted { set.remove(id) }
    }

    /// Drop IDs from `set` that are not present in `photos`. Used after
    /// filter / folder changes.
    static func reconcile(set: inout Set<UUID>, against photos: [Photo]) {
        let surviving = Set(photos.map(\.id))
        set.formIntersection(surviving)
    }

    /// Photo `direction` slots away from `from` in `photos`. `direction`
    /// of `+1` is next, `-1` is previous. Clamps at endpoints. Returns
    /// `photos.first?.id` when `from` is nil.
    static func neighbor(of from: UUID?, direction: Int, in photos: [Photo]) -> UUID? {
        guard !photos.isEmpty else { return nil }
        guard let from, let i = photos.firstIndex(where: { $0.id == from }) else {
            return photos.first?.id
        }
        let target = i + direction
        guard photos.indices.contains(target) else {
            return photos[i].id
        }
        return photos[target].id
    }
}
```

- [ ] **Step 4: Register the two new files in `project.pbxproj`**

Add `PhotoSelection.swift` to the SuperPicky app target and
`PhotoSelectionEditorTests.swift` to the SuperPickyTests target. Mirror the
pattern of `SpeciesAssignmentEditor.swift` (app) and
`SpeciesAssignmentEditorTests.swift` (tests). Each insertion needs:

1. A `PBXFileReference` line in the `Begin PBXFileReference section`.
2. A `PBXBuildFile` line for the appropriate target.
3. The file's UUID added to the parent `PBXGroup`'s `children` array.
4. The build-file UUID added to the target's `PBXSourcesBuildPhase`'s `files` array.

Use any existing entry's UUIDs as a template — generate fresh 24-hex-char
UUIDs for the new entries.

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/PhotoSelectionEditorTests
```

Expected: PASS, all 9 tests green.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PhotoSelection.swift \
        apps/mac-client/SuperPickyTests/Core/PhotoSelectionEditorTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(selection): pure PhotoSelectionEditor helpers + tests"
```

---

## Task 2: `PhotoSelection` `@Observable` wrapper

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PhotoSelection.swift`
- Test: `apps/mac-client/SuperPickyTests/Core/PhotoSelectionTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj` (register the new test file)

- [ ] **Step 1: Write the failing tests**

Create `apps/mac-client/SuperPickyTests/Core/PhotoSelectionTests.swift`:

```swift
import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoSelectionTests {

    private func makePhotos(_ count: Int, folder: URL = URL(fileURLWithPath: "/tmp/sel")) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "p\(i).CR3",
                  filePath: folder.appendingPathComponent("p\(i).CR3").path,
                  folderPath: folder.path)
        }
    }

    // MARK: - click

    @Test func clickSetsActiveAndAnchorAndCollapsesSelection() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        #expect(s.selectedIDs == [photos[1].id])
        #expect(s.activeID == photos[1].id)
        #expect(s.anchorID == photos[1].id)
        s.click(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[2].id)
    }

    // MARK: - shiftClick

    @Test func shiftClickWithoutAnchorBehavesLikePlainClick() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.shiftClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
    }

    @Test func shiftClickExtendsRangeFromAnchor() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos)
        #expect(s.selectedIDs == Set(photos[1...3].map(\.id)))
        #expect(s.activeID == photos[3].id)
        #expect(s.anchorID == photos[1].id) // unchanged
    }

    @Test func shiftClickReplacesPriorRangeFromSameAnchor() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[2].id, photos: photos)
        s.shiftClick(photos[4].id, photos: photos) // {2,3,4}
        s.shiftClick(photos[0].id, photos: photos) // {0,1,2}
        #expect(s.selectedIDs == Set(photos[0...2].map(\.id)))
        #expect(s.activeID == photos[0].id)
    }

    // MARK: - cmdClick

    @Test func cmdClickAddsAndUpdatesAnchorAndActive() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[0].id, photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[2].id)
    }

    @Test func cmdClickRemovesPresent() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[0].id])
    }

    @Test func cmdClickRemovingActiveFallsBackToFirstRemaining() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos) // active = p2
        s.cmdClick(photos[2].id, photos: photos) // remove p2
        #expect(s.activeID == photos[0].id)
        #expect(s.selectedIDs == [photos[0].id])
    }

    @Test func cmdClickEmptyingSelectionLeavesNilActive() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[0].id, photos: photos)
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
    }

    // MARK: - arrow

    @Test func arrowCollapsesAndMoves() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}
        s.arrow(direction: 1, photos: photos)
        #expect(s.selectedIDs == [photos[2].id]) // collapse to active+1? No — collapse to active first then move
        #expect(s.activeID == photos[2].id)
    }

    // Note: arrow's exact "collapse-then-move" semantics:
    // collapse to active (3), then move +1 → clamp to 3 (last). Verify here.
    @Test func arrowAtEndClampsToActive() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[3].id, photos: photos)
        s.arrow(direction: 1, photos: photos)
        #expect(s.activeID == photos[3].id)
        #expect(s.selectedIDs == [photos[3].id])
    }

    // MARK: - shiftArrow

    @Test func shiftArrowExtendsByOne() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftArrow(direction: 1, photos: photos)
        #expect(s.selectedIDs == [photos[1].id, photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[1].id)
    }

    @Test func shiftArrowAtEndIsNoOp() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftArrow(direction: 1, photos: photos)
        #expect(s.selectedIDs == [photos[1].id])
        #expect(s.activeID == photos[1].id)
    }

    // MARK: - selectAll / collapseToActive / clear

    @Test func selectAllPicksEveryPhoto() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.selectAll(photos: photos)
        #expect(s.selectedIDs == Set(photos.map(\.id)))
        #expect(s.activeID == photos[1].id) // active preserved
    }

    @Test func collapseToActiveDropsOthers() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.shiftClick(photos[2].id, photos: photos)
        s.collapseToActive()
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
    }

    @Test func clearEmptiesEverything() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.clear()
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
        #expect(s.anchorID == nil)
    }

    // MARK: - reconcile

    @Test func reconcileDropsMissingAndKeepsActiveIfPresent() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}, active=3
        s.reconcile(with: [photos[0], photos[2], photos[3]])
        #expect(s.selectedIDs == [photos[2].id, photos[3].id])
        #expect(s.activeID == photos[3].id)
    }

    @Test func reconcileFallsBackWhenActiveDropped() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}, active=3
        s.reconcile(with: [photos[0], photos[1], photos[2]])
        #expect(s.selectedIDs == [photos[1].id, photos[2].id])
        // Active was 3 (dropped) → first remaining selected by `photos`
        // order is photos[1].
        #expect(s.activeID == photos[1].id)
    }

    @Test func reconcileEmptyClearsAll() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.reconcile(with: [])
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/PhotoSelectionTests
```

Expected: FAIL with "cannot find 'PhotoSelection' in scope".

- [ ] **Step 3: Implement `PhotoSelection`**

Append to `apps/mac-client/SuperPickyApp/PhotoSelection.swift`:

```swift
import Observation

/// Multi-select state for the filmstrip. Backed by `PhotoSelectionEditor`
/// for the math; this wrapper owns observable state, click/keyboard
/// dispatch, and the activeID invariants.
///
/// Invariants:
///   - `activeID == nil` ⟺ `selectedIDs.isEmpty`
///   - `activeID != nil` ⟹ `selectedIDs.contains(activeID!)`
@Observable
final class PhotoSelection {
    private(set) var selectedIDs: Set<UUID> = []
    private(set) var activeID: UUID? = nil
    private(set) var anchorID: UUID? = nil

    var count: Int { selectedIDs.count }
    var isMulti: Bool { selectedIDs.count > 1 }
    func contains(_ id: UUID) -> Bool { selectedIDs.contains(id) }

    // MARK: - Click handlers

    func click(_ id: UUID, photos: [Photo]) {
        selectedIDs = [id]
        activeID = id
        anchorID = id
    }

    func shiftClick(_ id: UUID, photos: [Photo]) {
        guard let anchor = anchorID else {
            click(id, photos: photos); return
        }
        let range = PhotoSelectionEditor.rangeIDs(from: anchor, to: id, in: photos)
        guard !range.isEmpty else { return }
        selectedIDs = Set(range)
        activeID = id
        // anchor preserved
    }

    func cmdClick(_ id: UUID, photos: [Photo]) {
        let wasPresent = selectedIDs.contains(id)
        PhotoSelectionEditor.toggle(id, in: &selectedIDs)
        if wasPresent {
            // Removed; if it was the active, fall back.
            if activeID == id {
                activeID = firstSelectedInOrder(photos: photos)
            }
            // anchorID intentionally unchanged on cmd-remove.
        } else {
            activeID = id
            anchorID = id
        }
    }

    // MARK: - Keyboard

    func arrow(direction: Int, photos: [Photo]) {
        // Collapse to active first, then move.
        if let id = activeID {
            selectedIDs = [id]
            anchorID = id
        }
        guard let next = PhotoSelectionEditor.neighbor(
            of: activeID, direction: direction, in: photos
        ) else { return }
        selectedIDs = [next]
        activeID = next
        anchorID = next
    }

    func shiftArrow(direction: Int, photos: [Photo]) {
        guard let active = activeID,
              let next = PhotoSelectionEditor.neighbor(
                of: active, direction: direction, in: photos
              ),
              next != active else { return }
        selectedIDs.insert(next)
        activeID = next
        if anchorID == nil { anchorID = active }
    }

    func selectAll(photos: [Photo]) {
        selectedIDs = Set(photos.map(\.id))
        if activeID == nil || !selectedIDs.contains(activeID!) {
            activeID = photos.first?.id
            anchorID = activeID
        }
    }

    func collapseToActive() {
        guard let active = activeID else { selectedIDs = []; return }
        selectedIDs = [active]
        anchorID = active
    }

    // MARK: - Lifecycle

    func clear() {
        selectedIDs = []
        activeID = nil
        anchorID = nil
    }

    /// Drop IDs no longer present in `photos`. If the active was dropped,
    /// fall back to the first remaining selected (in `photos` order),
    /// else `photos.first?.id`, else nil.
    func reconcile(with photos: [Photo]) {
        PhotoSelectionEditor.reconcile(set: &selectedIDs, against: photos)
        if let active = activeID, selectedIDs.contains(active) {
            return
        }
        activeID = firstSelectedInOrder(photos: photos) ?? photos.first?.id
        if let anchor = anchorID, !selectedIDs.contains(anchor) {
            anchorID = activeID
        }
        if activeID == nil { selectedIDs = []; anchorID = nil }
    }

    // MARK: - Internals

    private func firstSelectedInOrder(photos: [Photo]) -> UUID? {
        photos.first(where: { selectedIDs.contains($0.id) })?.id
    }
}
```

- [ ] **Step 4: Register the test file in `project.pbxproj`**

Add `PhotoSelectionTests.swift` to SuperPickyTests target (PBXBuildFile +
PBXFileReference + group children + sources phase).

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/PhotoSelectionTests
```

Expected: PASS. If any test fails, fix the wrapper code (not the test) —
the invariants and semantics are spec-driven.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PhotoSelection.swift \
        apps/mac-client/SuperPickyTests/Core/PhotoSelectionTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(selection): @Observable PhotoSelection with click/keyboard handlers"
```

---

## Task 3: `BatchSpeciesAggregator`

**Files:**
- Create: `apps/mac-client/SuperPickyApp/BatchSpeciesAggregator.swift`
- Test: `apps/mac-client/SuperPickyTests/Core/BatchSpeciesAggregatorTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests**

Create `apps/mac-client/SuperPickyTests/Core/BatchSpeciesAggregatorTests.swift`:

```swift
import Testing
import Foundation
@testable import SuperPicky

@Suite struct BatchSpeciesAggregatorTests {

    private func match(_ ebird: String, common: String? = nil, conf: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: common ?? ebird.capitalized,
            confidence: conf,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: ebird
        )
    }

    private func photo(assigned: [SpeciesMatch], top5JSON: String? = nil) -> Photo {
        var p = Photo(filename: "p.CR3", filePath: "/tmp/p.CR3", folderPath: "/tmp")
        p.assignedSpecies = assigned
        p.speciesTop5JSON = top5JSON
        return p
    }

    // MARK: - unionAssigned

    @Test func unionAssignedReturnsEveryDistinctSpecies() {
        let a = match("eagle")
        let b = match("hawk")
        let c = match("owl")
        let photos = [
            photo(assigned: [a, b]),
            photo(assigned: [b, c]),
            photo(assigned: [a]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos)
        #expect(Set(result.map(\.species.speciesID)) == ["eagle", "hawk", "owl"])
    }

    @Test func unionAssignedCountsPhotosCarryingEach() {
        let a = match("eagle")
        let b = match("hawk")
        let photos = [
            photo(assigned: [a, b]),
            photo(assigned: [b]),
            photo(assigned: [b]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.species.speciesID, $0.photoCount) })
        #expect(byID["eagle"] == 1)
        #expect(byID["hawk"] == 3)
    }

    @Test func unionAssignedSortsByCountDescThenName() {
        let a = match("aaa", common: "AAA")
        let b = match("bbb", common: "BBB")
        let c = match("ccc", common: "CCC")
        let photos = [
            photo(assigned: [b]),
            photo(assigned: [b, c]),
            photo(assigned: [a, b]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos).map(\.species.speciesID)
        #expect(result == ["bbb", "aaa", "ccc"]) // bbb(3) > aaa(1)/ccc(1) tie broken by name
    }

    // MARK: - topCandidates

    @Test func topCandidatesUnionsTopKByMaxConfidence() throws {
        let a = match("eagle", conf: 0.4)
        let aHigh = match("eagle", conf: 0.8)
        let b = match("hawk", conf: 0.6)
        let c = match("owl", conf: 0.5)
        let json1 = try JSONEncoder().encode([a, b]).asString
        let json2 = try JSONEncoder().encode([aHigh, c]).asString
        let photos = [photo(assigned: [], top5JSON: json1),
                      photo(assigned: [], top5JSON: json2)]
        let result = BatchSpeciesAggregator.topCandidates(photos, limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.speciesID, $0.confidence) })
        #expect(byID["eagle"] == 0.8) // max wins
        #expect(byID["hawk"] == 0.6)
        #expect(byID["owl"] == 0.5)
        #expect(result.first?.speciesID == "eagle") // sorted by confidence desc
    }

    @Test func topCandidatesCapsAtLimit() throws {
        let many = (0..<15).map { match("sp\($0)", conf: Float(15 - $0) / 15) }
        let json = try JSONEncoder().encode(many).asString
        let p = photo(assigned: [], top5JSON: json)
        let result = BatchSpeciesAggregator.topCandidates([p], limit: 10)
        #expect(result.count == 10)
        #expect(result.first?.speciesID == "sp0") // highest confidence
    }

    @Test func topCandidatesIgnoresNilAndMalformedJSON() {
        let p1 = photo(assigned: [], top5JSON: nil)
        let p2 = photo(assigned: [], top5JSON: "not valid json")
        let result = BatchSpeciesAggregator.topCandidates([p1, p2], limit: 10)
        #expect(result.isEmpty)
    }
}

private extension Data {
    var asString: String { String(data: self, encoding: .utf8) ?? "" }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/BatchSpeciesAggregatorTests
```

Expected: FAIL with "cannot find 'BatchSpeciesAggregator'".

- [ ] **Step 3: Implement `BatchSpeciesAggregator`**

Create `apps/mac-client/SuperPickyApp/BatchSpeciesAggregator.swift`:

```swift
import Foundation

/// Aggregates species data across a set of photos for the batch-mode
/// species edit panel. Pure — no DB, no UI. Sibling to
/// `SpeciesAssignmentEditor`.
enum BatchSpeciesAggregator {

    struct AssignedRow {
        let species: SpeciesMatch
        let photoCount: Int
    }

    /// Union of `photo.assignedSpecies` across all `photos`. Returns one
    /// row per distinct `speciesID`, with `photoCount` = number of
    /// `photos` whose assigned list contains that species. Sorted by
    /// `photoCount` descending, then by `commonName` ascending (case-
    /// insensitive) for deterministic tie-breaks.
    static func unionAssigned(_ photos: [Photo]) -> [AssignedRow] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: SpeciesMatch] = [:]
        for photo in photos {
            for sp in photo.assignedSpecies {
                counts[sp.speciesID, default: 0] += 1
                if firstSeen[sp.speciesID] == nil {
                    firstSeen[sp.speciesID] = sp
                }
            }
        }
        return counts.map { id, count in
            AssignedRow(species: firstSeen[id]!, photoCount: count)
        }.sorted { lhs, rhs in
            if lhs.photoCount != rhs.photoCount {
                return lhs.photoCount > rhs.photoCount
            }
            let l = lhs.species.commonName ?? lhs.species.scientificName
            let r = rhs.species.commonName ?? rhs.species.scientificName
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }
    }

    /// Top `limit` candidates across `photos`, drawn from each photo's
    /// stored `speciesTop5JSON`. Deduped by `speciesID`. Each entry's
    /// confidence is the **max** observed across photos that surfaced it.
    /// Sorted by confidence descending, with `commonName` tie-break.
    /// Malformed or nil JSON contributes no candidates.
    static func topCandidates(_ photos: [Photo], limit: Int = 10) -> [SpeciesMatch] {
        var bestByID: [String: SpeciesMatch] = [:]
        for photo in photos {
            let cs = SpeciesAssignmentEditor.decodeCandidates(fromJSON: photo.speciesTop5JSON)
            for c in cs {
                if let existing = bestByID[c.speciesID] {
                    if c.confidence > existing.confidence {
                        bestByID[c.speciesID] = c
                    }
                } else {
                    bestByID[c.speciesID] = c
                }
            }
        }
        return bestByID.values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence {
                return lhs.confidence > rhs.confidence
            }
            let l = lhs.commonName ?? lhs.scientificName
            let r = rhs.commonName ?? rhs.scientificName
            return l.localizedCaseInsensitiveCompare(r) == .orderedAscending
        }.prefix(limit).map { $0 }
    }
}
```

- [ ] **Step 4: Register the new files in `project.pbxproj`**

Add `BatchSpeciesAggregator.swift` (app target) and
`BatchSpeciesAggregatorTests.swift` (tests target).

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/BatchSpeciesAggregatorTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/BatchSpeciesAggregator.swift \
        apps/mac-client/SuperPickyTests/Core/BatchSpeciesAggregatorTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(species): BatchSpeciesAggregator pure helper + tests"
```

---

## Task 4: Refactor `UndoAction` to entries shape

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift`

This is a no-behavior-change refactor. Existing tests must still pass.
Single-photo callers push 1-entry actions; the next task adds set-based
methods that push N-entry actions through the same shape.

- [ ] **Step 1: Define the new `UndoAction` shape and update the stack**

Replace the existing `UndoAction` struct (around line 98 of `AppState.swift`)
with:

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

The `undoStack: [UndoAction]` property type is unchanged.

- [ ] **Step 2: Update `mutatePhoto` to push 1-entry actions**

Modify `mutatePhoto(id:wasHidden:_:updateView:)` (around line 330) to capture
the full snapshot, including `previousAssignedSpecies`, into a 1-entry
`UndoAction`. Replace the existing `undoStack.append(UndoAction(...))` block
with:

```swift
let entry = UndoAction.Entry(
    photoID: id,
    previousRating: photo.starRating,
    previousIsPick: photo.isPick,
    previousIsManualRating: photo.isManualRating,
    previousAssignedSpecies: photo.assignedSpecies,
    wasHidden: wasHidden
)
undoStack.append(UndoAction(entries: [entry]))
if undoStack.count > Self.maxUndoDepth {
    undoStack.removeFirst()
}
```

- [ ] **Step 3: Update `undoLastAction` to iterate entries**

Replace the existing `undoLastAction()` body (around line 472) with:

```swift
func undoLastAction() {
    guard let action = undoStack.popLast() else { return }
    do {
        let database = try db()
        var anyPickChanged = false
        var lastID: UUID?
        for entry in action.entries {
            guard var photo = try database.fetchPhoto(id: entry.photoID) else { continue }
            let pickChanged = photo.isPick != entry.previousIsPick
            photo.starRating = entry.previousRating
            photo.isPick = entry.previousIsPick
            photo.isManualRating = entry.previousIsManualRating
            photo.assignedSpecies = entry.previousAssignedSpecies
            try database.save(&photo)
            _ = try? XMPWriter.write(photo: photo)

            if let idx = allPhotoIndex[entry.photoID] {
                allPhotos[idx] = photo
            }
            if pickChanged {
                speciesEntries = SpeciesHierarchyBuilder.applyPickToggle(
                    entries: speciesEntries, photo: photo, newIsPick: photo.isPick
                )
                anyPickChanged = true
            }
            if entry.wasHidden {
                if filteredPhotoIndex[photo.id] == nil {
                    filteredPhotoIndex[photo.id] = photos.count
                    photos.append(photo)
                }
            } else if let idx = filteredPhotoIndex[entry.photoID] {
                photos[idx] = photo
            }
            lastID = photo.id
        }
        // If species lists were restored, hierarchy may need a rebuild
        // (cheap compared to per-action perf risk).
        if action.entries.contains(where: { entry in
            allPhotoIndex[entry.photoID].flatMap { allPhotos[$0].assignedSpecies } != nil
        }) {
            buildSpeciesHierarchy()
        }
        _ = anyPickChanged // already applied per-photo above
        if let id = lastID { selection.activeID = id; selection.selectedIDs = [id] }
    } catch {
        logger.error("undoLastAction failed: \(error)")
    }
}
```

> **Note:** `selection.activeID = id` won't compile yet — `selection` is
> introduced in Task 7. For now, replace those two lines with the existing
> behavior `selectedPhotoID = lastID` and revisit in Task 7.

- [ ] **Step 4: Build & run existing tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: BUILD succeeds; all existing tests pass. The refactor is a
no-op behavior-wise; existing `AssignedSpeciesTests` and any others that
exercise `togglePick`/`ratePhoto`/`undoLastAction` should still pass.

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift
git commit -m "refactor(undo): UndoAction holds [Entry] for unified single+batch shape"
```

---

## Task 5: Replace single-arg pick / rate / reject with set-based methods

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift`
- Modify: `apps/mac-client/SuperPickyApp/MainView.swift`
- Test: `apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

- [ ] **Step 1: Write the failing tests for `setPick(ids:)`, `setRating`, `reject`**

Create `apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift`:

```swift
import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized) struct AppStateBatchMutationTests {

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func match(_ ebird: String, conf: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: ebird.capitalized,
            confidence: conf,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: ebird
        )
    }

    private func seedPhotos(_ count: Int, into folder: URL) throws -> [UUID] {
        let db = try ReportDatabase(folderPath: folder)
        var ids: [UUID] = []
        for i in 0..<count {
            var p = Photo(
                filename: "p\(i).CR3",
                filePath: folder.appendingPathComponent("p\(i).CR3").path,
                folderPath: folder.path
            )
            try db.save(&p)
            ids.append(p.id)
        }
        return ids
    }

    // MARK: - setPick(ids:)

    @Test func setPickPicksAllWhenAnyUnpicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        // Pick id[0] first to make a mixed-state set.
        app.setPick(ids: [ids[0]])
        let mixed = Set(ids[0...2])
        app.setPick(ids: mixed)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == true)
        }
    }

    @Test func setPickUnpicksAllWhenAllPicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        let s = Set(ids)
        app.setPick(ids: s) // pick all
        app.setPick(ids: s) // unpick all

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    @Test func setPickSinglePhotoMatchesLegacyToggleSemantics() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == true)
        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == false)
    }

    @Test func setPickPushesOneUndoEntry() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: Set(ids))
        let stackSizeAfter = app.undoStackSizeForTesting()
        #expect(stackSizeAfter == 1)

        app.undoLastAction()
        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    // MARK: - setRating(ids:rating:)

    @Test func setRatingAppliesToEveryID() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setRating(ids: Set(ids), rating: 4)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.starRating == 4)
        }
    }

    // MARK: - reject(ids:)

    @Test func rejectMakesPhotosLeaveFilteredArray() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.sidebarSelection = .rating(3)

        app.setRating(ids: Set(ids), rating: 3)
        app.applyFilter()
        #expect(app.photos.count == 3)

        app.reject(ids: [ids[0]])
        #expect(app.photos.count == 2)
        #expect(!app.photos.contains(where: { $0.id == ids[0] }))
    }
}
```

> **Note:** This test references two test-only accessors —
> `allPhotosForTesting()` and `undoStackSizeForTesting()` — added in step 3.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/AppStateBatchMutationTests
```

Expected: FAIL — `setPick(ids:)` / `setRating(ids:rating:)` / `reject(ids:)`
don't exist yet.

- [ ] **Step 3: Implement set-based methods, replace single-arg ones, add test accessors**

In `AppState.swift`, replace the existing `togglePick(id:)`, `ratePhoto(id:rating:)`,
and `rejectPhoto(id:)` (around lines 363–470) with the new set-based methods,
and add internal-test accessors near the top of the class:

```swift
// MARK: - Test-only accessors (kept internal)

#if DEBUG
func allPhotosForTesting() -> [Photo] { allPhotos }
func undoStackSizeForTesting() -> Int { undoStack.count }
#endif

// MARK: - Set-based mutation: pick / rate / reject

/// Pick semantics across `ids`: if any photo in `ids` is unpicked, pick
/// all of them; else unpick all. Explicit-only — does NOT fan out to
/// burst members.
func setPick(ids: Set<UUID>) {
    let targets = ids.compactMap { allPhotoIndex[$0].map { allPhotos[$0] } }
    guard !targets.isEmpty else { return }
    let anyUnpicked = targets.contains(where: { !$0.isPick })
    let newPick = anyUnpicked
    applyBatch(ids: targets.map(\.id)) { photo in
        photo.isPick = newPick
    } afterEach: { [weak self] photo in
        guard let self else { return }
        self.speciesEntries = SpeciesHierarchyBuilder.applyPickToggle(
            entries: self.speciesEntries, photo: photo, newIsPick: photo.isPick
        )
    }
}

func setRating(ids: Set<UUID>, rating: Int, manual: Bool = true) {
    applyBatch(ids: Array(ids)) { photo in
        photo.starRating = rating
        photo.isManualRating = manual
    }
}

func reject(ids: Set<UUID>) {
    applyBatch(ids: Array(ids), wasHidden: true) { photo in
        photo.starRating = 0
        photo.isManualRating = true
    } afterAll: { [weak self] _ in
        guard let self else { return }
        self.photos.removeAll { ids.contains($0.id) }
        self.rebuildFilteredPhotoIndex()
    }
}

// MARK: - Batch primitive

/// Apply `mutate` to every id in `ids` against the DB and XMP, snapshot
/// previous state into ONE `UndoAction`, update in-memory arrays, and
/// optionally invoke per-photo and end-of-batch hooks. Photos missing
/// from the DB are skipped.
private func applyBatch(
    ids: [UUID],
    wasHidden: Bool = false,
    _ mutate: (inout Photo) -> Void,
    afterEach: ((Photo) -> Void)? = nil,
    afterAll: ((_ mutated: [Photo]) -> Void)? = nil
) {
    guard !ids.isEmpty else { return }
    do {
        let database = try db()
        var entries: [UndoAction.Entry] = []
        var mutated: [Photo] = []
        for id in ids {
            guard var photo = try database.fetchPhoto(id: id) else { continue }
            entries.append(UndoAction.Entry(
                photoID: id,
                previousRating: photo.starRating,
                previousIsPick: photo.isPick,
                previousIsManualRating: photo.isManualRating,
                previousAssignedSpecies: photo.assignedSpecies,
                wasHidden: wasHidden
            ))
            mutate(&photo)
            try database.save(&photo)
            _ = try? XMPWriter.write(photo: photo)
            if let idx = allPhotoIndex[id] { allPhotos[idx] = photo }
            if let fIdx = filteredPhotoIndex[id] { photos[fIdx] = photo }
            mutated.append(photo)
            afterEach?(photo)
        }
        if !entries.isEmpty {
            undoStack.append(UndoAction(entries: entries))
            if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
        }
        afterAll?(mutated)
    } catch {
        logger.error("applyBatch failed: \(error)")
    }
}
```

> **Note:** `mutatePhoto(id:wasHidden:_:updateView:)` may stay as a thin
> shim that calls `applyBatch(ids: [id], wasHidden:, mutate)` so existing
> callers in this file (e.g. `correctSpecies`, `setAssignedSpecies`,
> `deletePhoto`) keep compiling. Task 6 replaces those callers and the
> shim is deleted there.

In `MainView.swift` (around line 109), update the callbacks passed to
`ContentView`:

```swift
onTogglePick: { id in
    appState.setPick(ids: [id])
},
onRatePhoto: { id, rating in
    appState.setRating(ids: [id], rating: rating)
},
onRejectPhoto: { id in
    appState.reject(ids: [id])
},
```

Update the legacy single-arg `mutatePhoto`-based callers in `AppState` —
e.g. the existing `setAssignedSpecies`/`correctSpecies` continue to call
`mutatePhoto(id:_:)` (the shim). The species methods are migrated in Task 6.

- [ ] **Step 4: Run all tests**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: PASS — both the new `AppStateBatchMutationTests` and existing tests.

- [ ] **Step 5: Register the new test file in `project.pbxproj`**

Add `AppStateBatchMutationTests.swift` to SuperPickyTests target.

- [ ] **Step 6: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift \
        apps/mac-client/SuperPickyApp/MainView.swift \
        apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(appstate): set-based setPick / setRating / reject + tests"
```

---

## Task 6: Replace single-arg species methods with set-based methods

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift`
- Modify: `apps/mac-client/SuperPickyApp/MainView.swift`
- Modify: `apps/mac-client/SuperPickyApp/ExifPanelView.swift` (callsites only — view body changes in Task 11)
- Test: append cases to `apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift`

- [ ] **Step 1: Append failing tests for the new species methods**

In `AppStateBatchMutationTests.swift`, add:

```swift
// MARK: - correctSpecies(ids:commonName:)

@Test func correctSpeciesAppliesPrimaryRenameAcrossSelection() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(3, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)

    // Seed each photo with the same primary so rename has something to
    // mutate.
    for id in ids {
        app.setPrimarySpecies(ids: [id], species: match("eagle"))
    }
    app.correctSpecies(ids: Set(ids), commonName: "Bald Eagle")

    let db = try ReportDatabase(folderPath: folder)
    for id in ids {
        let p = try db.fetchPhoto(id: id)!
        #expect(p.assignedSpecies.first?.commonName == "Bald Eagle")
    }
}

// MARK: - setPrimarySpecies(ids:species:)

@Test func setPrimarySpeciesAddsWhenMissingAndPromotesWhenPresent() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(3, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)

    // Photo 0: empty. Photo 1: already has eagle as secondary. Photo 2: empty.
    app.addSpecies(ids: [ids[1]], species: match("hawk"))
    app.addSpecies(ids: [ids[1]], species: match("eagle"))
    // ids[1].assigned = [hawk, eagle]

    app.setPrimarySpecies(ids: Set(ids), species: match("eagle"))

    let db = try ReportDatabase(folderPath: folder)
    let p0 = try db.fetchPhoto(id: ids[0])!
    let p1 = try db.fetchPhoto(id: ids[1])!
    let p2 = try db.fetchPhoto(id: ids[2])!
    #expect(p0.assignedSpecies.first?.speciesID == "eagle") // added as primary
    #expect(p1.assignedSpecies.first?.speciesID == "eagle") // promoted
    #expect(p2.assignedSpecies.first?.speciesID == "eagle") // added as primary
}

// MARK: - addSpecies(ids:species:)

@Test func addSpeciesIsIdempotentForExistingSpecies() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(2, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)

    app.addSpecies(ids: Set(ids), species: match("eagle"))
    app.addSpecies(ids: Set(ids), species: match("eagle"))

    let db = try ReportDatabase(folderPath: folder)
    for id in ids {
        let p = try db.fetchPhoto(id: id)!
        #expect(p.assignedSpecies.count == 1)
        #expect(p.assignedSpecies.first?.speciesID == "eagle")
    }
}

// MARK: - removeSpecies(ids:species:)

@Test func removeSpeciesNoOpsWhenAbsent() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(2, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)

    app.addSpecies(ids: [ids[0]], species: match("eagle"))
    app.removeSpecies(ids: Set(ids), species: match("hawk"))

    let db = try ReportDatabase(folderPath: folder)
    let p0 = try db.fetchPhoto(id: ids[0])!
    let p1 = try db.fetchPhoto(id: ids[1])!
    #expect(p0.assignedSpecies.map(\.speciesID) == ["eagle"]) // unchanged
    #expect(p1.assignedSpecies.isEmpty)
}

@Test func removeSpeciesDropsFromEveryPhotoThatHasIt() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(3, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)
    app.addSpecies(ids: Set(ids), species: match("eagle"))

    app.removeSpecies(ids: Set(ids), species: match("eagle"))

    let db = try ReportDatabase(folderPath: folder)
    for id in ids {
        #expect(try db.fetchPhoto(id: id)!.assignedSpecies.isEmpty)
    }
}

// MARK: - Burst fan-out (Q9)

@Test func setPrimarySpeciesFansOutToBurstMembers() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let db = try ReportDatabase(folderPath: folder)

    let burstID = UUID()
    var burstIDs: [UUID] = []
    for i in 0..<3 {
        var p = Photo(filename: "burst_\(i).CR3",
                      filePath: folder.appendingPathComponent("burst_\(i).CR3").path,
                      folderPath: folder.path)
        p.burstGroupID = burstID
        try db.save(&p)
        burstIDs.append(p.id)
    }

    let app = AppState()
    app.loadPhotos(for: folder)

    // Select only ONE burst member; species edit must fan out to all 3.
    app.setPrimarySpecies(ids: [burstIDs[0]], species: match("eagle"))

    for id in burstIDs {
        let p = try db.fetchPhoto(id: id)!
        #expect(p.assignedSpecies.first?.speciesID == "eagle")
    }
}

// MARK: - Undo restores species

@Test func undoRestoresAssignedSpeciesAfterBatchEdit() throws {
    let folder = try makeTempFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let ids = try seedPhotos(3, into: folder)
    let app = AppState()
    app.loadPhotos(for: folder)
    app.addSpecies(ids: Set(ids), species: match("eagle"))

    app.setPrimarySpecies(ids: Set(ids), species: match("hawk"))
    app.undoLastAction()

    let db = try ReportDatabase(folderPath: folder)
    for id in ids {
        let p = try db.fetchPhoto(id: id)!
        #expect(p.assignedSpecies.map(\.speciesID) == ["eagle"])
    }
}
```

- [ ] **Step 2: Run new tests to verify they fail**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/AppStateBatchMutationTests
```

Expected: FAIL — set-based species methods don't exist; old single-arg
`setAssignedSpecies(id:species:)` is referenced in tests-not-yet-written
form.

- [ ] **Step 3: Implement set-based species methods**

In `AppState.swift`, delete the existing `correctSpecies(id:commonName:)`
(line ~410) and `setAssignedSpecies(id:species:)` (line ~453). Add:

```swift
// MARK: - Set-based mutation: species

/// Inline rename of primary across `ids`. Each id's burst members are
/// included (Q9 fan-out). Empty `commonName` is preserved as today.
func correctSpecies(ids: Set<UUID>, commonName: String) {
    let trimmed = commonName.trimmingCharacters(in: .whitespaces)
    let targets = expandBurstMembers(of: ids)
    applyBatch(ids: targets) { photo in
        var list = photo.assignedSpecies
        if var first = list.first {
            first = SpeciesMatch(
                scientificName: first.scientificName,
                commonName: trimmed.isEmpty ? nil : trimmed,
                confidence: first.confidence,
                cnName: first.cnName,
                pinyin: first.pinyin,
                pinyinInitials: first.pinyinInitials,
                thresholdUsed: first.thresholdUsed,
                ebirdCode: first.ebirdCode
            )
            list[0] = first
            photo.assignedSpecies = list
        } else if !trimmed.isEmpty {
            photo.assignedSpecies = [SpeciesMatch(
                scientificName: trimmed,
                commonName: trimmed,
                confidence: 0,
                cnName: nil, pinyin: nil,
                thresholdUsed: "manual", ebirdCode: nil
            )]
        }
    } afterAll: { [weak self] _ in
        self?.buildSpeciesHierarchy()
    }
}

/// Set `species` as primary across `ids` (with burst fan-out). For each
/// target photo: if `species` isn't already assigned, ADD it then
/// promote to slot 0; else move existing entry to slot 0.
func setPrimarySpecies(ids: Set<UUID>, species: SpeciesMatch) {
    let targets = expandBurstMembers(of: ids)
    applyBatch(ids: targets) { photo in
        var list = photo.assignedSpecies
        if let idx = list.firstIndex(where: { $0.speciesID == species.speciesID }) {
            list = SpeciesAssignmentEditor.makePrimary(at: idx, in: list)
        } else {
            list.insert(species, at: 0)
        }
        photo.assignedSpecies = list
    } afterAll: { [weak self] _ in
        self?.buildSpeciesHierarchy()
    }
}

/// Add `species` to every target photo (with burst fan-out) that doesn't
/// already have it. No-op for photos that already carry the species.
func addSpecies(ids: Set<UUID>, species: SpeciesMatch) {
    let targets = expandBurstMembers(of: ids)
    applyBatch(ids: targets) { photo in
        if let updated = SpeciesAssignmentEditor.add(species, to: photo.assignedSpecies) {
            photo.assignedSpecies = updated
        }
    } afterAll: { [weak self] _ in
        self?.buildSpeciesHierarchy()
    }
}

/// Remove `species` from every target photo (with burst fan-out) that
/// has it.
func removeSpecies(ids: Set<UUID>, species: SpeciesMatch) {
    let targets = expandBurstMembers(of: ids)
    applyBatch(ids: targets) { photo in
        if let idx = photo.assignedSpecies.firstIndex(where: { $0.speciesID == species.speciesID }) {
            photo.assignedSpecies = SpeciesAssignmentEditor.remove(at: idx, from: photo.assignedSpecies)
        }
    } afterAll: { [weak self] _ in
        self?.buildSpeciesHierarchy()
    }
}

/// Expand `ids` to include every burst member of every selected photo.
/// Order: `ids` first (de-duped), then burst-member-only IDs in
/// `allPhotos` order. The `applyBatch` body is order-independent for
/// these methods, so this just keeps undo-entry order deterministic.
private func expandBurstMembers(of ids: Set<UUID>) -> [UUID] {
    var result: [UUID] = []
    var seen: Set<UUID> = []
    func add(_ id: UUID) {
        if seen.insert(id).inserted { result.append(id) }
    }
    for id in ids { add(id) }
    for id in ids {
        for member in burstMemberIDs(for: id) where member != id {
            add(member)
        }
    }
    return result
}
```

Delete the stub `mutatePhoto(id:wasHidden:_:updateView:)` shim left over
from Task 5 — every call site is now set-based.

In `MainView.swift` (lines 128–133), update the callbacks:

```swift
onCorrectSpecies: { id, name in
    appState.correctSpecies(ids: [id], commonName: name)
},
onAssignedSpeciesChanged: { id, species in
    // Single-photo "replace whole list" path: clear then rebuild via
    // primary + adds. Order is preserved.
    if let primary = species.first {
        appState.setPrimarySpecies(ids: [id], species: primary)
        for sp in species.dropFirst() {
            appState.addSpecies(ids: [id], species: sp)
        }
    } else {
        // Empty list: remove every existing species.
        if let photo = appState.selectedPhoto {
            for sp in photo.assignedSpecies {
                appState.removeSpecies(ids: [id], species: sp)
            }
        }
    }
},
```

> **Note:** the "replace whole list" path is a temporary shim — Task 11
> rewires the species panel to call set-based methods directly.

- [ ] **Step 4: Run all tests**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: PASS — including the existing `AssignedSpeciesTests` and the
new species cases. If `AssignedSpeciesTests` references the old
`setAssignedSpecies(id:species:)`, update it to use
`setPrimarySpecies(ids:species:)` + `addSpecies(ids:species:)`.

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift \
        apps/mac-client/SuperPickyApp/MainView.swift \
        apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift \
        apps/mac-client/SuperPickyTests/Core/AppStateBatchMutationTests.swift
git commit -m "feat(species): set-based correctSpecies/setPrimary/add/remove (burst fan-out)"
```

---

## Task 7: Compose `PhotoSelection` into `AppState`

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift`

- [ ] **Step 1: Add the `selection` property and lifecycle hooks**

In `AppState.swift`, around line 70 (right next to `selectedPhotoID`), add:

```swift
let selection = PhotoSelection()

/// Back-compat accessor. Reads/writes `selection.activeID`. New code
/// should use `selection` directly.
var selectedPhotoID: UUID? {
    get { selection.activeID }
    set {
        if let id = newValue {
            // Keep call sites that assign IDs working: behave like a plain
            // click (collapses any prior multi-select).
            selection.click(id, photos: photos)
        } else {
            selection.clear()
        }
    }
}
```

Delete the original `var selectedPhotoID: UUID?` declaration. Update
`selectedPhoto` to read from `selection.activeID`:

```swift
var selectedPhoto: Photo? {
    guard let id = selection.activeID else { return nil }
    return photos.first { $0.id == id }
}
```

In `clearPhotos()`:

```swift
func clearPhotos() {
    allPhotos = []
    photos = []
    allPhotoIndex = [:]
    filteredPhotoIndex = [:]
    speciesEntries = []
    selection.clear()
    currentFolder = nil
    undoStack = []
}
```

In `applyFilter()`, append at the bottom:

```swift
selection.reconcile(with: photos)
```

In `loadPhotos(for:skipHierarchy:)` — replace the existing
"Preserve selection if the photo still exists" block with:

```swift
// Reconcile selection against the filtered list. Active falls back per
// PhotoSelection.reconcile invariants.
selection.reconcile(with: photos)
if selection.activeID == nil, let first = photos.first {
    selection.click(first.id, photos: photos)
}
```

In `undoLastAction()` — replace the deferred `selectedPhotoID = lastID`
note from Task 4 with the proper call:

```swift
if let id = lastID {
    if let photoInFiltered = photos.first(where: { $0.id == id }) {
        selection.click(photoInFiltered.id, photos: photos)
    }
}
```

- [ ] **Step 2: Build and run all tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: BUILD succeeds; all tests pass. Existing call sites that read
`appState.selectedPhotoID` keep working through the back-compat
property.

- [ ] **Step 3: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift
git commit -m "feat(appstate): compose PhotoSelection; selectedPhotoID is back-compat passthrough"
```

---

## Task 8: `MouseClickRedirector`

**Files:**
- Create: `apps/mac-client/SuperPickyApp/MouseClickRedirector.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

No L1 unit test — this is an `NSViewRepresentable` that drives event
dispatch; coverage comes via the L3 click tests in Task 14. A smoke
test would require a real NSWindow, which is heavy for what's effectively
a 30-line wrapper.

- [ ] **Step 1: Create the file**

`apps/mac-client/SuperPickyApp/MouseClickRedirector.swift`:

```swift
import AppKit
import SwiftUI

/// A zero-size SwiftUI background view that installs an NSEvent local
/// monitor for `.leftMouseDown` and reports `(point-in-window, modifier-
/// flags)` to its callback. Intended to back the filmstrip so multi-
/// select clicks can carry shift / cmd modifiers — `.onTapGesture`
/// silently drops modifier flags. Pattern mirrors `ScrollWheelRedirector`.
struct MouseClickRedirector: NSViewRepresentable {
    typealias OnClick = (_ pointInWindow: NSPoint, _ modifiers: NSEvent.ModifierFlags) -> Bool

    let onClick: OnClick

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.onClick = onClick
    }

    /// Internal NSView that owns the monitor token's lifetime, attached
    /// to the view via objc-association rather than a property so the
    /// representable struct remains value-typed.
    private final class MonitorView: NSView {
        var onClick: OnClick?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      let cb = self.onClick else { return event }
                let pointInWindow = event.locationInWindow
                if cb(pointInWindow, event.modifierFlags) {
                    return nil // consume
                }
                return event
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { removeMonitor() }
    }
}
```

- [ ] **Step 2: Register in `project.pbxproj`**

Add to SuperPicky app target.

- [ ] **Step 3: Build to confirm it compiles**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
```

Expected: BUILD succeeds.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/MouseClickRedirector.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(strip): MouseClickRedirector for modifier-aware clicks"
```

---

## Task 9: `ThumbnailStripView` selection-aware

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ThumbnailStripView.swift`
- Modify: `apps/mac-client/SuperPickyApp/ContentView.swift` (pass selection through, render counter)

- [ ] **Step 1: Update `ThumbnailStripView` to take `PhotoSelection`**

Replace the existing `ThumbnailStripView` (entire file body — top of file
to about line 113 — keep `ThumbnailCache` and `AsyncThumbnailImage`
below) with:

```swift
import SwiftUI
import AppKit

struct ThumbnailStripView: View {
    let photos: [Photo]
    @Bindable var selection: PhotoSelection

    var body: some View {
        let selectedBurstGroupID: UUID? = {
            guard let id = selection.activeID else { return nil }
            return photos.first(where: { $0.id == id })?.burstGroupID
        }()
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        ThumbnailCell(
                            photo: photo,
                            isActive: photo.id == selection.activeID,
                            isSelected: selection.contains(photo.id),
                            isDimmed: ThumbnailCell.shouldDim(
                                photoBurstGroupID: photo.burstGroupID,
                                selectedBurstGroupID: selectedBurstGroupID
                            )
                        )
                        .id(photo.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .background(ScrollWheelRedirector())
            .background(MouseClickRedirector { pointInWindow, modifiers in
                handleClick(pointInWindow: pointInWindow, modifiers: modifiers)
            })
            .background(.bar)
            .onChange(of: selection.activeID) { _, newValue in
                if let id = newValue {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// Hit-test the click point against thumbnail accessibility rects.
    /// Returns true if a thumbnail was hit (and a selection mutation
    /// happened); the caller consumes the event.
    private func handleClick(pointInWindow: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        // Walk every thumbnail's NSAccessibilityElement-rectangle by
        // identifier. SwiftUI exposes the cell as an NSView via the
        // accessibility tree — find the deepest NSView at point and walk
        // up to the cell.
        guard let view = window.contentView?.hitTest(pointInWindow) else { return false }
        // Cell views carry an accessibility identifier "Thumbnail_<filename>".
        let id = ThumbnailCell.findThumbnailIdentifier(from: view)
        guard let id, let photo = photos.first(where: { "Thumbnail_\($0.filename)" == id })
        else { return false }
        if modifiers.contains(.shift) {
            selection.shiftClick(photo.id, photos: photos)
        } else if modifiers.contains(.command) {
            selection.cmdClick(photo.id, photos: photos)
        } else {
            selection.click(photo.id, photos: photos)
        }
        return true
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let isActive: Bool
    let isSelected: Bool
    let isDimmed: Bool

    static func shouldDim(photoBurstGroupID: UUID?, selectedBurstGroupID: UUID?) -> Bool {
        guard let selected = selectedBurstGroupID else { return false }
        return photoBurstGroupID != selected
    }

    /// Walk an NSView ancestry chain looking for a SwiftUI-exposed
    /// accessibility identifier of the form "Thumbnail_<filename>".
    static func findThumbnailIdentifier(from view: NSView) -> String? {
        var current: NSView? = view
        while let v = current {
            if let id = v.accessibilityIdentifier(),
               id.hasPrefix("Thumbnail_") {
                return id
            }
            current = v.superview
        }
        return nil
    }

    private var borderColor: Color {
        if isActive { return .accentColor }
        if isSelected { return .accentColor.opacity(0.5) }
        if photo.isPick { return .orange.opacity(0.6) }
        return .clear
    }

    private var a11ySelectionValue: String {
        if isActive { return "active" }
        if isSelected { return "selected" }
        return "none"
    }

    var body: some View {
        ZStack {
            AsyncThumbnailImage(filePath: photo.filePath)
                .aspectRatio(3/2, contentMode: .fit)
                .clipped()

            if photo.isPick {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(2)
                    .transition(.opacity)
                    .accessibilityIdentifier("PickFlag_\(photo.filename)")
            }

            if photo.isBurstBest {
                Image(systemName: "crown.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }

            StarRatingView(rating: photo.starRating)
                .padding(2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.2), value: photo.isPick)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: 2)
        )
        .opacity(isDimmed ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
        .accessibilityIdentifier("Thumbnail_\(photo.filename)")
        .accessibilityValue(a11ySelectionValue)
    }
}
```

- [ ] **Step 2: Update `ContentView` to pass `selection` to the strip and render counter**

In `ContentView.swift`:

1. Replace the `selectedPhotoID: Binding<UUID?>` plumbing where it's used
   to pass to the strip with the `appState.selection` value. Find:

   ```swift
   ThumbnailStripView(
       photos: filteredPhotos,
       selectedPhotoID: $selectedPhotoID
   )
   ```

   Replace with:

   ```swift
   ThumbnailStripView(
       photos: filteredPhotos,
       selection: appState.selection
   )
   ```

   This requires `ContentView` to take an `appState: AppState` parameter
   if it doesn't already; if it currently takes `selectedPhotoID:
   Binding<UUID?>` and other slices, broaden to take the full `AppState`
   reference.

   > **Note:** If broadening signatures, keep all existing callbacks
   > (`onRatePhoto`, `onTogglePick`, etc.) for now — Task 10 simplifies
   > the keyboard handlers but doesn't have to remove the callbacks.

2. Update the photo counter line (around line 183):

   ```swift
   HStack(spacing: 8) {
       if appState.selection.isMulti {
           Text("\(appState.selection.count) selected")
               .font(.caption)
               .foregroundStyle(.tint)
               .accessibilityIdentifier("SelectionCounter")
       }
       Text("\(filteredPhotos.count) of \(photos.count)")
           .font(.caption)
           .foregroundStyle(.secondary)
           .accessibilityIdentifier("PhotoCounter")
           .accessibilityValue("\(filteredPhotos.count) of \(photos.count)")
   }
   ```

- [ ] **Step 3: Build and smoke-run**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
```

Expected: BUILD succeeds.

Optional manual smoke (developer machine only — not CI): launch the app
on a folder with 3+ processed photos, click one thumbnail, then shift-
click another, then cmd-click a third. Verify visually that the active
photo gets the bright accent border and the others get the dimmer
accent border. Counter reads "N selected · M of K".

- [ ] **Step 4: Run L1 tests**

```bash
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ThumbnailStripView.swift \
        apps/mac-client/SuperPickyApp/ContentView.swift
git commit -m "feat(strip): selection-aware ThumbnailStripView with shift/cmd-click"
```

---

## Task 10: Keyboard updates in `ContentView`

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ContentView.swift`

- [ ] **Step 1: Update `handleKey` for arrow / shift+arrow / cmd+A / esc / batch keys**

In `ContentView.swift`'s `handleKey(_:)` (around line 293), replace the
entire body with:

```swift
private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
    if showKeyboardHelp { showKeyboardHelp = false; return true }

    let selection = appState.selection
    let filtered = filteredPhotos

    // Arrow keys: shift extends, plain collapses-and-moves.
    if key.isLeftArrow || key.isRightArrow {
        let dir = key.isLeftArrow ? -1 : 1
        if key.modifiers.contains(.shift) {
            selection.shiftArrow(direction: dir, photos: filtered)
        } else {
            selection.arrow(direction: dir, photos: filtered)
        }
        return true
    }

    // Esc: exit fullscreen, else collapse selection.
    if key.isEscape {
        if showFullscreen { showFullscreen = false; return true }
        if selection.isMulti { selection.collapseToActive(); return true }
        return false
    }

    // Cmd+A: select all in filteredPhotos.
    if key.modifiers.contains(.command), key.characters == "a" {
        selection.selectAll(photos: filtered)
        return true
    }

    // Cmd+Z: undo (single-photo or batch transparently).
    if key.modifiers.contains(.command), key.characters == "z" {
        if canUndo { onUndo?() }
        return canUndo
    }

    // Cmd+E: export picks.
    if key.modifiers.contains(.command), key.characters == "e" {
        onExportPicks?()
        return onExportPicks != nil
    }

    // Cmd+0–5: minimum-stars filter.
    if key.modifiers.contains(.command),
       let char = key.characters.first,
       let digit = char.wholeNumberValue,
       (0...5).contains(digit) {
        minimumStars = digit
        return true
    }

    let ids = selection.selectedIDs
    let isMulti = selection.isMulti

    switch key.characters {
    case "i":
        withAnimation(.easeInOut(duration: 0.2)) { showExifPanel.toggle() }
        return true
    case "f":
        showFullscreen.toggle()
        return true
    case "c":
        if filtered.count >= 2 { showCompare.toggle() }
        return true
    case "p":
        guard !ids.isEmpty else { return false }
        appState.setPick(ids: ids)
        if !isMulti, config.autoAdvance { navigatePhoto(direction: 1) }
        return true
    case "x":
        guard !ids.isEmpty else { return false }
        if !isMulti { navigatePhoto(direction: 1, fallbackToPrevious: true) }
        appState.reject(ids: ids)
        return true
    case "0", "1", "2", "3", "4", "5":
        guard !ids.isEmpty,
              let digit = key.characters.first?.wholeNumberValue else { return true }
        appState.setRating(ids: ids, rating: digit)
        if !isMulti, config.autoAdvance { navigatePhoto(direction: 1) }
        return true
    case "z":
        guard let photo = selectedPhoto else { return false }
        let imagePixelWidth = ImageLoader.pixelSize(path: photo.filePath)?.width ?? previewSize.width * 2
        let activeZoom = showFullscreen ? fullscreenZoomState : zoomState
        let viewSize = showFullscreen
            ? (NSApp.keyWindow?.frame.size ?? previewSize)
            : previewSize
        activeZoom.toggleFitActualPixelsAt(
            imagePixelWidth: imagePixelWidth,
            viewSize: viewSize,
            mouseInView: mouseInPreview
        )
        return true
    case "=", "+":
        brightnessAdj = min(brightnessAdj + 0.05, 0.5); return true
    case "-":
        brightnessAdj = max(brightnessAdj - 0.05, -0.5); return true
    case "?":
        showKeyboardHelp = true; return true
    default: break
    }

    if key.keyCode == 51 {
        guard let id = selectedPhoto?.id else { return false }
        pendingDeleteID = id
        showDeleteConfirm = true
        return true
    }

    return false
}
```

> **Note:** This now reaches `appState` directly inside `ContentView`.
> If `ContentView` doesn't already have `appState`, add `let appState:
> AppState` as a property and pass it from `MainView`. The
> `onTogglePick` / `onRatePhoto` / `onRejectPhoto` callbacks become
> dead-weight — remove them from `ContentView`'s parameter list and from
> the `MainView.swift` call site to keep things lean.

- [ ] **Step 2: Build and run L1 tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: BUILD succeeds; tests pass.

- [ ] **Step 3: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ContentView.swift \
        apps/mac-client/SuperPickyApp/MainView.swift
git commit -m "feat(keys): batch p/0-5/x; shift+arrow extend; cmd+A; esc collapse"
```

---

## Task 11: `SpeciesEditPanelView` batch mode

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ExifPanelView.swift`

- [ ] **Step 1: Survey the existing panel**

Read the current `SpeciesEditPanelView` body (inside `ExifPanelView.swift`).
The view currently takes a single `Photo` and surfaces three sections:

1. Header (filename / inline rename)
2. Assigned list (X / Make-primary buttons)
3. Candidates list (Add buttons sourced from `photo.speciesTop5JSON`)
4. Search field for adding by name

The branching changes only the data source for sections 2 and 3 plus the
header copy.

- [ ] **Step 2: Add selection-aware inputs to `SpeciesEditPanelView`**

Modify the view's parameters so it takes the full `AppState` (or at
minimum the `PhotoSelection` plus the aggregated photos for that
selection). The minimal change:

```swift
struct SpeciesEditPanelView: View {
    @Environment(CullingConfig.self) private var config
    let appState: AppState
    let activePhoto: Photo
    let searchSpecies: (String) -> [SpeciesMatch]
    // ... existing local @State for search query, etc.

    private var selection: PhotoSelection { appState.selection }

    private var selectedPhotos: [Photo] {
        let ids = selection.selectedIDs
        if ids.isEmpty { return [activePhoto] }
        return appState.photos.filter { ids.contains($0.id) }
    }
    private var isMulti: Bool { selection.isMulti }
    ...
}
```

Then update the body sections:

**Header** (replace existing single-photo title):

```swift
HStack {
    if isMulti {
        Text(String(format: config.localized("Editing %lld photos"), selection.count))
            .font(.headline)
    } else {
        Text(activePhoto.filename).font(.headline)
    }
    Spacer()
}
```

**Assigned section data source** — replace the current
`activePhoto.assignedSpecies` iteration with:

```swift
private var assignedRows: [BatchSpeciesAggregator.AssignedRow] {
    isMulti
        ? BatchSpeciesAggregator.unionAssigned(selectedPhotos)
        : activePhoto.assignedSpecies.map { BatchSpeciesAggregator.AssignedRow(species: $0, photoCount: 1) }
}
```

In the assigned-row iteration:

```swift
ForEach(assignedRows, id: \.species.speciesID) { row in
    HStack {
        Text(row.species.commonName ?? row.species.scientificName)
        if isMulti && row.photoCount < selectedPhotos.count {
            Text(" (\(row.photoCount)/\(selectedPhotos.count))")
                .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
            appState.setPrimarySpecies(ids: targetIDs, species: row.species)
        } label: { Image(systemName: "star") }
            .accessibilityIdentifier(A11y.speciesEditMakePrimary(row.species.speciesID))
            .help(config.localized("Make primary"))
        Button {
            appState.removeSpecies(ids: targetIDs, species: row.species)
        } label: { Image(systemName: "xmark") }
            .accessibilityIdentifier(A11y.speciesEditRemove(row.species.speciesID))
    }
}
```

Where:

```swift
private var targetIDs: Set<UUID> {
    isMulti ? selection.selectedIDs : [activePhoto.id]
}
```

**Candidates section data source** — replace
`SpeciesAssignmentEditor.decodeCandidates(...)` with:

```swift
private var candidates: [SpeciesMatch] {
    if isMulti {
        return BatchSpeciesAggregator.topCandidates(selectedPhotos, limit: 10)
    } else {
        let assignedIDs = Set(activePhoto.assignedSpecies.map(\.speciesID))
        return SpeciesAssignmentEditor
            .decodeCandidates(fromJSON: activePhoto.speciesTop5JSON)
            .filter { !assignedIDs.contains($0.speciesID) }
    }
}
```

The "Add" button per candidate:

```swift
Button { appState.addSpecies(ids: targetIDs, species: candidate) }
    label: { Image(systemName: "plus") }
    .accessibilityIdentifier(A11y.speciesEditAdd(candidate.speciesID))
```

**Search submit:**

```swift
.onSubmit {
    if let match = searchResults.first {
        appState.addSpecies(ids: targetIDs, species: match)
        searchQuery = ""
    }
}
```

**Update the call site** — wherever `SpeciesEditPanelView` is created
(inside `ExifPanelView`'s body), pass `appState` and the active photo:

```swift
SpeciesEditPanelView(
    appState: appState,
    activePhoto: activePhoto,
    searchSpecies: searchSpecies
)
```

The previous `onAssignedSpeciesChanged` callback chain in `MainView.swift`
becomes dead — remove it (the temporary shim from Task 6).

- [ ] **Step 3: Build and run L1 tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: BUILD succeeds; tests pass.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ExifPanelView.swift \
        apps/mac-client/SuperPickyApp/MainView.swift
git commit -m "feat(species-panel): batch mode (union assigned + max-confidence top 10)"
```

---

## Task 12: `InfoBarView` inline rename batch

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ExifPanelView.swift` *(or wherever InfoBar lives — search for InfoBarView)*

- [ ] **Step 1: Find and inspect the InfoBar inline rename**

```bash
grep -rn "InfoBar\|inline rename\|onCorrectSpecies" apps/mac-client/SuperPickyApp/
```

The species rename TextField passes its commit handler through
`onCorrectSpecies` (currently single-id callback). This task wires it to
the new set-based method and adds the multi-select annotation.

- [ ] **Step 2: Update the TextField commit handler and label**

In the InfoBar species-rename block, change the commit to call the
set-based method with the current selection's ids:

```swift
TextField(
    "",
    text: $editingPrimaryName,
    onCommit: {
        let ids: Set<UUID> = appState.selection.selectedIDs.isEmpty
            ? [activePhoto.id]
            : appState.selection.selectedIDs
        appState.correctSpecies(ids: ids, commonName: editingPrimaryName)
    }
)
```

Add a "(N selected)" suffix label when `appState.selection.isMulti`:

```swift
HStack(spacing: 4) {
    Text(activePhoto.assignedSpecies.first?.commonName ?? "")
        // ... existing styling
    if appState.selection.isMulti {
        Text("(\(appState.selection.count) selected)")
            .font(.caption)
            .foregroundStyle(.tint)
    }
}
```

- [ ] **Step 3: Build and run L1 tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ExifPanelView.swift
git commit -m "feat(infobar): inline species rename applies to selection (with N-selected tag)"
```

---

## Task 13: `KeyboardHelpView` + `A11y.swift` updates

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/KeyboardHelpView.swift`
- Modify: `apps/mac-client/SuperPickyUITests/A11y.swift`
- Modify: `apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings`
- Modify: `apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: Document new shortcuts in the help view**

Open `KeyboardHelpView.swift`. Append to the existing rows:

```swift
HelpRow(keys: "⇧←/→", description: config.localized("Extend selection"))
HelpRow(keys: "⌘A", description: config.localized("Select all"))
HelpRow(keys: "esc", description: config.localized("Collapse selection"))
```

And update the `p` / `0`–`5` / `x` row descriptions to reflect that they
operate on the current selection (1 photo or many):

```swift
HelpRow(keys: "P", description: config.localized("Pick / unpick selection"))
HelpRow(keys: "0–5", description: config.localized("Rate selection"))
HelpRow(keys: "X", description: config.localized("Reject selection"))
```

- [ ] **Step 2: Add localizations**

In both `Localizable.strings` files (en and zh-Hans), add:

en:
```
"Extend selection" = "Extend selection";
"Select all" = "Select all";
"Collapse selection" = "Collapse selection";
"Pick / unpick selection" = "Pick / unpick selection";
"Rate selection" = "Rate selection";
"Reject selection" = "Reject selection";
"Editing %lld photos" = "Editing %lld photos";
"%lld selected" = "%lld selected";
```

zh-Hans:
```
"Extend selection" = "扩展选择";
"Select all" = "全选";
"Collapse selection" = "折叠选择";
"Pick / unpick selection" = "选择/取消选择";
"Rate selection" = "评分选择";
"Reject selection" = "拒绝选择";
"Editing %lld photos" = "正在编辑 %lld 张照片";
"%lld selected" = "已选 %lld 张";
```

> **Note:** Per the project rule (memory: "Localize ALL UI strings"),
> any English string passed to `config.localized(...)` must have a
> Chinese counterpart. Sweep the Task 9 / 11 / 12 strings — "%lld
> selected", "Editing %lld photos", "(N selected)" caption — and ensure
> each is in both `.strings` files. Replace the literal "(\(count)
> selected)" patterns with `String(format: config.localized("%lld
> selected"), count)` where used.

- [ ] **Step 3: Add A11y identifiers for selection**

In `apps/mac-client/SuperPickyUITests/A11y.swift`, append:

```swift
static let selectionCounter = "SelectionCounter"

/// Accessibility values used by ThumbnailCell — match
/// `ThumbnailCell.a11ySelectionValue`.
enum ThumbnailSelection: String {
    case active = "active"
    case selected = "selected"
    case none = "none"
}
```

- [ ] **Step 4: Build and run L1 tests**

```bash
cd apps/mac-client && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'
cd apps/mac-client && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/KeyboardHelpView.swift \
        apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings \
        apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings \
        apps/mac-client/SuperPickyUITests/A11y.swift
git commit -m "docs(keys): document multi-select shortcuts; add localizations + a11y ids"
```

---

## Task 14: L3 BDD tests (`BatchSelectionUITests`)

**Files:**
- Create: `apps/mac-client/SuperPickyUITests/BatchSelectionUITests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`

- [ ] **Step 1: Create the BDD test class**

`apps/mac-client/SuperPickyUITests/BatchSelectionUITests.swift`:

```swift
import XCTest

/// XCUITest coverage for filmstrip multi-select and batch operations.
/// Per project rules:
///   - All `waitForExistence` results are XCTAssert'd (silent-timeout rule).
///   - Off-screen thumbnails are reached via `arrowStripUntil`
///     (LazyHStack lazy-instantiation rule).
///   - On-disk side effects (XMP) are read after each batch op
///     (verify-disk-side-effects rule).
final class BatchSelectionUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_batch" }

    private var app: XCUIApplication { Self.app }
    private var testDir: String { Self.testDir }

    // MARK: - Helpers

    private func clickThumbnail(_ filename: String,
                                 modifiers: XCUIElement.KeyModifierFlags = []) {
        let thumb = app.images[A11y.thumbnail(filename)]
        XCTAssertTrue(thumb.waitForExistence(timeout: 5),
                      "Thumbnail \(filename) never appeared")
        if modifiers.isEmpty {
            thumb.click()
        } else {
            // XCUIElement.click(forDuration:thenDragTo:) doesn't honor
            // modifier flags; use the keyboard-modifier-aware tap helper:
            XCUIElement.perform(withKeyModifiers: modifiers) {
                thumb.click()
            }
        }
    }

    private func a11ySelection(of filename: String) -> String? {
        app.images[A11y.thumbnail(filename)].value as? String
    }

    private func selectionCounterText() -> String {
        let counter = app.staticTexts[A11y.selectionCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 2),
                      "SelectionCounter never appeared")
        return counter.label
    }

    private func xmp(for filename: String) throws -> String {
        let path = (testDir as NSString)
            .appendingPathComponent((filename as NSString)
                .deletingPathExtension + ".xmp")
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - Tests

    func testShiftClickRangeSelectsContiguousThumbnails() {
        // Pick the first three filenames the fixture exposes; production
        // fixtures live under SuperPickyUITests/test-photos. Anchor on
        // photo[0], shift-click photo[2] → select 0,1,2.
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)

        XCTAssertEqual(a11ySelection(of: names[0]), "selected")
        XCTAssertEqual(a11ySelection(of: names[1]), "selected")
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
        XCTAssertTrue(selectionCounterText().contains("3"))
    }

    func testCmdClickTogglesIndividualSelection() {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .command)
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
        XCTAssertEqual(a11ySelection(of: names[0]), "selected")

        clickThumbnail(names[2], modifiers: .command)
        XCTAssertEqual(a11ySelection(of: names[2]), "none")
    }

    func testCmdAUsesSelectAll() {
        clickThumbnail(fixtureFilenames(prefix: 1)[0])
        XCUIElement.perform(withKeyModifiers: .command) {
            app.typeKey("a", modifierFlags: .command)
        }
        // Counter should match filtered count.
        let counter = app.staticTexts[A11y.selectionCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 2))
        XCTAssertTrue(counter.label.contains("selected"))
    }

    func testEscCollapsesMultiSelect() {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts[A11y.selectionCounter].exists)
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
    }

    func testBatchPickViaKeyboard() throws {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])

        for n in names {
            XCTAssertTrue(app.images[A11y.thumbnail(n)]
                .waitForExistence(timeout: 2))
            // Pick flag overlay accessibility id.
            XCTAssertTrue(app.images["PickFlag_\(n)"].exists,
                          "Pick flag missing for \(n)")
            // XMP sidecar should reflect pick status (xmp:Label = "Pick"
            // or `lr:hierarchicalSubject` includes "Pick" — match the
            // app's actual XMPWriter output).
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("Pick") || body.contains("xmp:Label"),
                          "XMP for \(n) does not reflect pick state")
        }
    }

    func testBatchUnpickViaKeyboard() {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])
        app.typeKey("p", modifierFlags: [])
        for n in names {
            XCTAssertFalse(app.images["PickFlag_\(n)"].exists,
                           "Pick flag should be cleared for \(n)")
        }
    }

    func testBatchRateSetsStarsOnAllSelected() throws {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("3", modifierFlags: [])
        for n in names {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("Rating>3<") || body.contains("xmp:Rating=\"3\""),
                          "XMP for \(n) does not show 3-star rating")
        }
    }

    func testBatchSpeciesSetPrimaryViaPanel() throws {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("i", modifierFlags: [])

        let search = app.textFields[A11y.speciesEditPanelSearchField]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Bald Eagle\n")

        for n in names {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("Bald Eagle"),
                          "XMP for \(n) does not list Bald Eagle as a species")
        }
    }

    func testOneStepUndoForBatchEdit() {
        let names = fixtureFilenames(prefix: 3)
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])
        app.typeKey("z", modifierFlags: .command)
        for n in names {
            XCTAssertFalse(app.images["PickFlag_\(n)"].exists,
                           "Pick flag should be cleared after undo")
        }
    }

    func testFolderChangeClearsSelection() {
        let names = fixtureFilenames(prefix: 2)
        clickThumbnail(names[0])
        clickThumbnail(names[1], modifiers: .shift)
        // Trigger a folder/clear simulation: switch sidebar to Picks
        // (no items) and back to Folder. Behaviour: selection reconciles.
        app.outlines.staticTexts["Picks"].click()
        // Counter should disappear if no overlap.
        XCTAssertFalse(app.staticTexts[A11y.selectionCounter].exists)
    }

    // MARK: - Fixture filename discovery

    private func fixtureFilenames(prefix count: Int) -> [String] {
        let url = SuperPickyUITestCase.fixturesRoot
            .appendingPathComponent(Self.fixtureFolder)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .filter { $0.hasSuffix(".jpg") }
            .sorted() ?? []
        return Array(names.prefix(count))
    }
}
```

> **Note on XMP assertions:** the exact XMP key for pick state depends
> on what `XMPWriter` writes — check
> `apps/mac-client/SuperPickyApp/XMPWriter.swift` and replace the
> `body.contains("Pick")` / `body.contains("xmp:Label")` checks with the
> actual key (e.g. `crs:Pick="True"` or `xmp:Label>Pick<`). Same for
> rating — use whatever XMPWriter emits.

- [ ] **Step 2: Register in `project.pbxproj`**

Add `BatchSelectionUITests.swift` to SuperPickyUITests target.

- [ ] **Step 3: Verify build (don't run XCUITest locally)**

```bash
cd apps/mac-client && xcodebuild build-for-testing -scheme SuperPicky -destination 'platform=macOS'
```

Expected: BUILD succeeds. Per `CLAUDE.md`, do NOT run XCUITest locally —
push to CI.

- [ ] **Step 4: Commit and let CI run**

```bash
git add apps/mac-client/SuperPickyUITests/BatchSelectionUITests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "test(l3): batch-selection XCUITests (click, pick, rate, species, undo)"
```

After push: monitor CI per the "Watch CI until green" memory rule —
poll `gh run` and fix any reds before handing back.

---

## Self-Review

**Spec coverage walkthrough:**

| Spec section | Implemented in |
|---|---|
| `PhotoSelection` model + invariants | Tasks 1, 2 |
| `PhotoSelectionEditor` pure helpers | Task 1 |
| Composition into `AppState` + lifecycle hooks | Task 7 |
| `MouseClickRedirector` | Task 8 |
| 3-state thumbnail border + a11y values | Task 9 |
| Selection counter | Task 9 |
| Keyboard: arrow / shift+arrow / cmd+A / esc | Task 10 |
| Keyboard: batch p / 0–5 / x with auto-advance suppression | Task 10 |
| Unified `UndoAction` (entries) | Task 4 |
| Set-based pick / rate / reject | Task 5 |
| Set-based species methods (correctSpecies, setPrimary, add, remove) | Task 6 |
| Burst fan-out for species | Task 6 |
| `BatchSpeciesAggregator` (union assigned, top-N candidates) | Task 3 |
| Species panel batch mode | Task 11 |
| InfoBar inline rename batch mode | Task 12 |
| Localized strings | Task 13 |
| Keyboard help view updates | Task 13 |
| L1 tests for selection / aggregator / mutations / undo | Tasks 1–6 |
| L3 XCUITest coverage | Task 14 |

**Placeholder scan:** no "TBD", "TODO", or "implement later" left in
the plan. Two notes in Tasks 4 and 5 explicitly forward-reference work
done in later tasks (`selection.activeID = id` initially deferred; the
`mutatePhoto` shim deleted in Task 6).

**Type consistency:**
- `PhotoSelection` API names (`click`, `shiftClick`, `cmdClick`, `arrow`,
  `shiftArrow`, `selectAll`, `collapseToActive`, `clear`, `reconcile`)
  match between Tasks 2, 7, 9, 10.
- `AppState` set-based method signatures match between Tasks 5, 6, 10,
  11, 12.
- `BatchSpeciesAggregator.AssignedRow.{species, photoCount}` matches
  between Tasks 3 and 11.
- `UndoAction.Entry.{photoID, previousRating, previousIsPick,
  previousIsManualRating, previousAssignedSpecies, wasHidden}` is
  consistent across Tasks 4, 5, 6.

No remaining issues.

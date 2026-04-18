# Species edit applies to the entire burst

**Date:** 2026-04-18
**Status:** approved

## Problem

When a photo is part of a burst (`Photo.burstGroupID != nil`), every frame in
the burst is visually near-identical and almost always depicts the same
bird(s). Today, species edits target one photo at a time, forcing the user
to repeat the same correction on every burst member. This creates silent
inconsistency: the sidebar hierarchy, sidecar keywords, and downstream
exports diverge across frames that should be identical.

## Behavior

Any species edit on a photo with a non-nil `burstGroupID` is propagated to
every photo that shares the same `burstGroupID`. Photos with
`burstGroupID == nil` continue to behave as single-photo edits.

Two edit paths propagate:

1. **Full-panel edit** — `AppState.setAssignedSpecies(id:species:)`, invoked
   from `ExifPanelView` when the user adds, removes, reorders, or replaces
   species. Every burst member receives the same `[SpeciesMatch]` list.

2. **Inline primary rename** — `AppState.correctSpecies(id:commonName:)`,
   invoked from `InfoBarView` when the user renames the primary species
   without changing its `speciesID`. Every burst member has its primary
   `commonName` rewritten:
   - Members that already have an `assignedSpecies` keep their existing
     `speciesID` / `scientificName` / `confidence` / `cnName` / `pinyin` /
     `thresholdUsed` / `ebirdCode` on the primary entry, and only the
     `commonName` changes.
   - Members with an empty `assignedSpecies` get the same "new custom entry"
     branch as the single-photo path today (scientific and common name both
     set to `trimmed`), so they leave the Unidentified bucket alongside
     the rest of the burst.

Propagation happens inside `AppState`; no call sites change.

## Non-goals

- **No per-photo escape hatch.** There is no modifier key, toggle, or
  "apply to burst" checkbox. Choice C: edits to a burst member always
  expand to the whole burst.
- **No undo changes.** Species edits are not tracked by the undo stack
  today; that stays as-is. `mutatePhoto` will still push one undo entry
  per member (noisy but harmless — those entries only record rating /
  pick / hidden state, which the species mutation does not change).
- **No UI changes.** No badges, confirms, or labels signaling that an edit
  will fan out.
- **No XCUITest coverage in this change.** The species-edit XCUITests are
  currently flaky; adding a burst variant now would amplify the noise.
  Revisit once the existing flakes are fixed.

## Implementation sketch

Both methods live in `apps/mac-client/SuperPickyApp/AppState.swift`.

A private helper resolves the burst member IDs for a given photo:

```swift
private func burstMemberIDs(for id: UUID) -> [UUID] {
    guard
        let idx = allPhotoIndex[id],
        let groupID = allPhotos[idx].burstGroupID
    else {
        return [id]
    }
    return allPhotos.filter { $0.burstGroupID == groupID }.map(\.id)
}
```

`setAssignedSpecies(id:species:)` loops over `burstMemberIDs(for: id)`,
calls the existing `mutatePhoto` for each, and calls
`buildSpeciesHierarchy()` exactly once at the end.

`correctSpecies(id:commonName:)` loops over `burstMemberIDs(for: id)`,
applies the same rename logic that exists today (the branch for an
empty `assignedSpecies` vs. the branch that rewrites `list[0]`) per
member, and calls `buildSpeciesHierarchy()` once at the end.

Per-member `mutatePhoto` continues to: save to DB, write the XMP sidecar,
update `allPhotos` + `photos` in-memory. No changes to `mutatePhoto` itself.

## Testing

L1 unit tests only. Add to
`apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`:

1. **Burst fan-out — full panel edit.** Seed 3 photos with the same
   `burstGroupID` and 1 solo photo (no burst group). Call
   `setAssignedSpecies` on one burst member with a new list. Assert every
   burst member has the new list and the solo photo is untouched.

2. **Burst fan-out — inline rename.** Same seeding. Call `correctSpecies`
   on one burst member with a new common name. Assert every burst member's
   primary `commonName` is updated while `speciesID` / `scientificName`
   are preserved. Solo photo untouched.

3. **Solo photo unaffected.** `setAssignedSpecies` and `correctSpecies` on
   a photo with `burstGroupID == nil` still edit exactly that photo.

Gates: L1 via `scripts/pre-commit.sh` on the pre-commit hook.

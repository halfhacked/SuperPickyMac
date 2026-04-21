# Burst appears under every tagged species in the sidebar

**Date:** 2026-04-20
**Status:** approved

## Problem

When a burst member's `assignedSpecies` carries more than one species entry,
the sidebar attaches that burst to only one species bucket — the burst's
"dominant primary species" (highest-confidence `assignedSpecies.first`
across members). Every other tagged species still gets a sidebar row with
a non-zero `count` (because bucket membership uses the full union), but
its `burstGroups` is empty and `singlePhotos` is 0. Users see a row like
"Hawk (3)" with nothing to click into.

After the fan-out feature shipped (PR #33), this edge case is common, not
rare: any time a user adds a secondary species to a burst member, the
secondary species gets a visibly broken sidebar row.

## Behavior

A burst appears under every species bucket that any of its members is
tagged with. Concretely, for each burst group:

- Compute the union of `SpeciesMatch.speciesID` across the burst's
  members' `assignedSpecies` lists.
- For every species in that union, the burst's `BurstGroupEntry` is
  attached to that species' `SpeciesEntry.burstGroups`.
- `BurstGroupEntry.count` stays the **total burst size** (all members,
  not just members tagged with this species), so clicking the same
  burst in any bucket drills into the same set of photos.

Solo (non-burst) photos already appear under every species they are
tagged with (`SpeciesHierarchyBuilder.swift:74-81`). No change there.

Unidentified burst members (empty `assignedSpecies`) contribute their
burst to the Unidentified bucket — same rule applied to the
`unidentifiedKey` sentinel.

## Non-goals

- **No change to solo multi-species photos.** Already correct.
- **No change to fan-out.** `AppState.setAssignedSpecies` /
  `AppState.correctSpecies` stay as they are.
- **No change to `applyIncremental`.** Its existing doc comment already
  states burst-group membership is only materialized by the full
  rebuild at end-of-ingest (`SpeciesHierarchyBuilder.swift:27-31`). User
  edits go through the full-rebuild path, so the bug is fully fixed by
  changing `build(from:)`.
- **No UI changes.** Sidebar row rendering, filter predicates
  (`AppState.photoHasSpeciesID`), and drill-down behavior all stay.
- **No count semantics change for partially-tagged bursts.** If member A
  is `[Eagle]` and member B is `[Eagle, Hawk]`, the Hawk bucket shows
  the burst with its full size (2) even though only 1 member is tagged
  Hawk. Post-fan-out this case is rare; acceptable.

## Implementation sketch

Single file: `apps/mac-client/SuperPickyApp/SpeciesHierarchyBuilder.swift`.

1. **Build a per-burst species set** alongside `burstPhotos`:

   ```swift
   var burstSpecies: [UUID: Set<String>] = [:]  // groupID → speciesIDs
   ```

   While iterating `photos` in the first pass (lines 36-49), collect every
   `speciesID` in every burst member's `assignedSpecies`. If a burst has
   only unidentified members (no species at all), store
   `[unidentifiedKey]` so the burst still shows under Unidentified.

2. **Replace the `burstPrimaryByGroup` filter** in the bucket-build pass
   (lines 88-98) with a set-membership check:

   ```swift
   for photo in bucket.photos {
       if let groupID = photo.burstGroupID {
           burstGroupIDs.insert(groupID)
       } else {
           singleCount += 1
       }
   }
   ```

   Because `bucket.photos` only contains photos whose `assignedSpecies`
   includes `id`, any burst member appearing here implies the burst is
   tagged with `id`, which is exactly the condition we want.

3. **Drop `burstPrimaryByGroup` / `burstBestConfidence`.** Their only
   consumer was the filter above. Removing them keeps `build(from:)`
   smaller and eliminates a second pass over `photos`.

4. **Rewrite the existing test**
   `multiSpeciesPhotoInBurstAppearsOnceUnderDominantSpeciesBucket`
   (`SpeciesHierarchyTests.swift:360`) to assert the new behavior:
   both Eagle and Hawk buckets include the burst. Rename to
   `multiSpeciesBurstAppearsUnderEveryTaggedSpecies`.

5. **Add one new AppState-level test**
   (`AssignedSpeciesTests.swift`) that exercises the full user flow:
   fan-out a secondary species onto a burst, rebuild hierarchy via
   `loadPhotos`, assert both species buckets list the burst.

## Verification

- `swift test --filter SpeciesHierarchyTests` — rewritten test green,
  neighbors untouched.
- `swift test --filter AssignedSpeciesTests` — new fan-out/sidebar test
  green, 9 pre-existing green.
- `swift test` full suite green twice (shared-state flake memory).
- `scripts/pre-commit.sh` green.

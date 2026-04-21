# Burst Appears Under Every Tagged Species — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A burst whose members are tagged with more than one species appears under every tagged species in the sidebar, not only under the dominant primary species' bucket.

**Architecture:** `SpeciesHierarchyBuilder.build` drops the "burst → dominant primary only" filter. Because `bucket.photos` is already built from the union of members' `assignedSpecies`, the fix is a one-line filter removal plus deletion of the now-unused `burstPrimaryByGroup` / `burstBestConfidence` helpers. No AppState changes, no UI changes.

**Tech Stack:** Swift / Swift Testing, `SpeciesHierarchyBuilder` is a pure-computation struct.

**Spec:** `docs/superpowers/specs/2026-04-20-burst-appears-under-every-tagged-species-design.md`

---

## File Structure

- **Modify** `apps/mac-client/SuperPickyApp/SpeciesHierarchyBuilder.swift`
  - Delete `burstPrimaryByGroup` and `burstBestConfidence`.
  - Collapse the first-pass loop (36-49) to just populate `burstPhotos`.
  - Replace the per-bucket filter (88-98) so every burst-member photo adds its groupID to `burstGroupIDs` unconditionally.

- **Modify** `apps/mac-client/SuperPickyTests/Core/SpeciesHierarchyTests.swift`
  - Rewrite and rename `multiSpeciesPhotoInBurstAppearsOnceUnderDominantSpeciesBucket` → `multiSpeciesBurstAppearsUnderEveryTaggedSpecies`.

- **Modify** `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`
  - Add one new test covering the full user flow: fan-out secondary species onto a burst, rebuild, assert both sidebar buckets carry the burst.

---

## Task 1: Red test at the `SpeciesHierarchyBuilder` level

**Files:**
- Test: `apps/mac-client/SuperPickyTests/Core/SpeciesHierarchyTests.swift`

- [ ] **Step 1: Rewrite and rename the test**

Open `apps/mac-client/SuperPickyTests/Core/SpeciesHierarchyTests.swift` and replace the entire `multiSpeciesPhotoInBurstAppearsOnceUnderDominantSpeciesBucket` test body (starting at line 360) with:

```swift
    @Test func multiSpeciesBurstAppearsUnderEveryTaggedSpecies() throws {
        // Burst members each tagged primary=Eagle; one of them also carries
        // a secondary Hawk tag. The burst should appear under BOTH Eagle
        // and Hawk in the sidebar so the secondary bucket isn't an empty
        // drill-down.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        var a = makePhoto(folder: folder, filename: "A.CR3", burstGroupID: burstID)
        a.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila", commonName: "Eagle",
                         confidence: 0.95, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "eagle"),
        ]
        var b = makePhoto(folder: folder, filename: "B.CR3", burstGroupID: burstID)
        b.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila", commonName: "Eagle",
                         confidence: 0.92, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "eagle"),
            SpeciesMatch(scientificName: "Accipiter", commonName: "Hawk",
                         confidence: 0.30, cnName: nil, pinyin: nil,
                         thresholdUsed: "country", ebirdCode: "hawk"),
        ]
        try setupDB(folder: folder, photos: [a, b])

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.speciesID == "eagle" }
        let hawk = appState.speciesEntries.first { $0.speciesID == "hawk" }

        // Both buckets show the burst with the full burst size.
        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 2)
        #expect(hawk?.burstGroups.count == 1)
        #expect(hawk?.burstGroups.first?.count == 2)
        #expect(eagle?.burstGroups.first?.id == hawk?.burstGroups.first?.id)

        // Bucket-level count: Eagle counts both members (both tagged Eagle);
        // Hawk counts only the member actually tagged Hawk.
        #expect(eagle?.count == 2)
        #expect(hawk?.count == 1)
    }
```

- [ ] **Step 2: Run the test, verify it fails**

```bash
cd apps/mac-client && swift test --filter SpeciesHierarchyTests.multiSpeciesBurstAppearsUnderEveryTaggedSpecies 2>&1 | tail -30
```

Expected: FAIL — `hawk?.burstGroups.count == 1` is violated because current code filters burst to dominant-primary only, so Hawk has `burstGroups.count == 0`.

- [ ] **Step 3: Commit the red test**

```bash
cd /Users/dazhen/projects/SuperPickyMac-sidebar-burst
git add apps/mac-client/SuperPickyTests/Core/SpeciesHierarchyTests.swift
git commit -m "test(sidebar): red test for burst appearing under every tagged species"
```

---

## Task 2: Drop the dominant-primary filter in `SpeciesHierarchyBuilder.build`

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/SpeciesHierarchyBuilder.swift`

- [ ] **Step 1: Simplify the first-pass loop**

Replace the current lines 27-53 (the two-pass burst-primary computation) with just the `burstPhotos` collection:

```swift
        // Group burst members by group ID so we can emit a single
        // BurstGroupEntry per burst, with the total member count.
        var burstPhotos: [UUID: [Photo]] = [:]
        for photo in photos {
            guard let groupID = photo.burstGroupID else { continue }
            burstPhotos[groupID, default: []].append(photo)
        }
```

Delete the `burstPrimaryByGroup` and `burstBestConfidence` declarations entirely.

- [ ] **Step 2: Drop the filter in the per-bucket loop**

Replace the current burstGroupIDs loop (lines 88-98):

```swift
            for photo in bucket.photos {
                if let groupID = photo.burstGroupID {
                    if burstPrimaryByGroup[groupID] == id {
                        burstGroupIDs.insert(groupID)
                    }
                } else {
                    singleCount += 1
                }
            }
```

with:

```swift
            for photo in bucket.photos {
                if let groupID = photo.burstGroupID {
                    burstGroupIDs.insert(groupID)
                } else {
                    singleCount += 1
                }
            }
```

The safety of dropping the filter follows from `bucket.photos` already being built from the per-species union at lines 74-81 — every photo in `bucket.photos` has `id` in its `assignedSpecies`, so its burst is legitimately tagged with `id`.

- [ ] **Step 3: Update the doc comment at the top of the struct**

Replace lines 3-13:

```swift
/// Pure computation: groups photos into species hierarchy entries.
///
/// A photo may carry multiple species in its `assignedSpecies` list; the
/// builder emits one contribution *per assigned species*, so a photo
/// tagged with both A and B appears under both buckets. The primary
/// (first) entry still drives burst-dominant-species assignment so a
/// burst lives under one species only.
///
/// Bucket identity is `SpeciesMatch.speciesID` (eBird code or, when the
/// user entered a custom species, the scientific name). Never the
/// localized common name — renames don't jump buckets.
```

with:

```swift
/// Pure computation: groups photos into species hierarchy entries.
///
/// A photo may carry multiple species in its `assignedSpecies` list; the
/// builder emits one contribution *per assigned species*, so a photo
/// tagged with both A and B appears under both buckets. Bursts follow
/// the same rule: a burst whose members are tagged with species A and B
/// appears under both A and B, each with a `BurstGroupEntry` carrying
/// the full burst size.
///
/// Bucket identity is `SpeciesMatch.speciesID` (eBird code or, when the
/// user entered a custom species, the scientific name). Never the
/// localized common name — renames don't jump buckets.
```

- [ ] **Step 4: Run the failing test to verify it passes**

```bash
cd apps/mac-client && swift test --filter SpeciesHierarchyTests.multiSpeciesBurstAppearsUnderEveryTaggedSpecies 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 5: Run the full `SpeciesHierarchyTests` suite to confirm no regressions**

```bash
cd apps/mac-client && swift test --filter SpeciesHierarchyTests 2>&1 | tail -20
```

Expected: PASS — every other test still green. `photoWithTwoSpeciesAppearsInBothBuckets` still passes because its photos have `burstGroupID == nil` (solo path unchanged). Tests asserting "burst appears once" with a single-species burst still pass because the per-burst species union is a singleton.

- [ ] **Step 6: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac-sidebar-burst
git add apps/mac-client/SuperPickyApp/SpeciesHierarchyBuilder.swift
git commit -m "feat(sidebar): burst appears under every tagged species"
```

---

## Task 3: End-to-end AppState test for the fan-out + sidebar flow

**Files:**
- Test: `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`

- [ ] **Step 1: Add the integration test**

Append this test after `setAssignedSpeciesOnSoloPhotoDoesNotTouchOtherPhotos` (the regression test added by PR #33):

```swift
    @Test func burstFanOutWithSecondarySpeciesAppearsUnderBothSidebarBuckets() throws {
        // Start with a burst where every member is tagged Eagle.
        // Edit one member's species list to [Eagle, Hawk] — fan-out
        // propagates [Eagle, Hawk] to every burst member.
        // After rebuilding the hierarchy, the burst should appear under
        // BOTH Eagle and Hawk in the sidebar.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        let eagle = match(sci: "Aquila", common: "Eagle", ebird: "eagle")

        let burstID = UUID()
        var burstIDs: [UUID] = []
        for i in 0..<3 {
            var p = makePhoto(folder: folder, filename: "burst_\(i).CR3")
            p.burstGroupID = burstID
            p.assignedSpecies = [eagle]
            try db.save(&p)
            burstIDs.append(p.id)
        }

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = match(sci: "Accipiter", common: "Hawk", ebird: "hawk")
        appState.setAssignedSpecies(id: burstIDs[0], species: [eagle, hawk])

        let eagleEntry = appState.speciesEntries.first { $0.speciesID == "eagle" }
        let hawkEntry = appState.speciesEntries.first { $0.speciesID == "hawk" }
        #expect(eagleEntry?.burstGroups.count == 1)
        #expect(eagleEntry?.burstGroups.first?.count == 3)
        #expect(hawkEntry?.burstGroups.count == 1)
        #expect(hawkEntry?.burstGroups.first?.count == 3)
        #expect(eagleEntry?.burstGroups.first?.id == burstID)
        #expect(hawkEntry?.burstGroups.first?.id == burstID)
    }
```

- [ ] **Step 2: Run the test**

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.burstFanOutWithSecondarySpeciesAppearsUnderBothSidebarBuckets 2>&1 | tail -20
```

Expected: PASS — Task 2's fix already covers this, so this test is additive regression coverage for the user-facing flow, not a red-then-green step.

- [ ] **Step 3: Run the full `AssignedSpeciesTests` suite**

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests 2>&1 | tail -20
```

Expected: PASS for all 10 tests (9 from PR #33 + this new one).

- [ ] **Step 4: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac-sidebar-burst
git add apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift
git commit -m "test(sidebar): end-to-end fan-out + sidebar bucket coverage"
```

---

## Task 4: Full-suite verification + pre-commit gate

- [ ] **Step 1: Run the full suite twice**

Per project memory ("Run tests before push — twice if shared state"):

```bash
cd apps/mac-client && swift test 2>&1 | tail -5
```

Expected: PASS.

```bash
cd apps/mac-client && swift test 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 2: Run the pre-commit gate**

```bash
cd /Users/dazhen/projects/SuperPickyMac-sidebar-burst
scripts/pre-commit.sh 2>&1 | tail -20
```

Expected: PASS (G1 static + L1 unit).

- [ ] **Step 3: Push + open PR**

```bash
cd /Users/dazhen/projects/SuperPickyMac-sidebar-burst
git push -u origin feat/sidebar-multispecies-burst
gh pr create --base main --head feat/sidebar-multispecies-burst \
  --title "fix(sidebar): burst appears under every tagged species" \
  --body "..."
```

---

## Out of scope (confirm in review)

- No changes to `AppState` mutation methods, `Photo`, `ReportDatabase`, or any UI view.
- No changes to `applyIncremental` — burst grouping during ingest is intentionally skipped there per its existing comment.
- No XCUITest — species-edit XCUITests are still flagged as flaky.
- No count-semantics change for partially-tagged bursts (rare post-fan-out).

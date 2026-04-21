# Species Edit Applies to Burst Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a user edits species on a photo that belongs to a burst, the same edit is applied to every photo in that burst; solo photos (no `burstGroupID`) behave as before.

**Architecture:** Both edit entry points (`AppState.setAssignedSpecies` and `AppState.correctSpecies`) resolve a list of burst-member IDs via a shared private helper, iterate the existing `mutatePhoto` over each member, and call `buildSpeciesHierarchy()` once after all mutations complete. No UI, DB schema, or `mutatePhoto` changes.

**Tech Stack:** Swift / Swift Testing, GRDB-backed `ReportDatabase`, `AppState` as the mutation surface.

**Spec:** `docs/superpowers/specs/2026-04-18-species-edit-applies-to-burst-design.md`

---

## File Structure

- **Modify** `apps/mac-client/SuperPickyApp/AppState.swift` (single file)
  - Add private `burstMemberIDs(for id: UUID) -> [UUID]` helper.
  - Change `setAssignedSpecies(id:species:)` to iterate over burst members.
  - Change `correctSpecies(id:commonName:)` to iterate over burst members, preserving the existing two branches (rewrite `list[0]` vs. create a custom entry when `assignedSpecies` is empty).

- **Modify** `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift` (add cases — do not rewrite existing tests)
  - Seed helpers for a burst trio and a solo photo.
  - Three new `@Test` cases covering fan-out of both methods and the solo-unaffected case.

---

## Task 1: Seed helper for burst fixtures + failing burst fan-out test for `setAssignedSpecies`

**Files:**
- Test: `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`

- [ ] **Step 1: Add a fixture helper that seeds three burst members + one solo photo**

Open `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`. Add the helper inside the `AssignedSpeciesTests` struct, directly after the existing `match(...)` helper (around line 34, in the `// MARK: - Helpers` section):

```swift
    /// Seed a fresh folder + DB with a 3-photo burst (all sharing `burstID`)
    /// plus one solo photo (no burst group). Returns the folder URL, the
    /// burst member IDs (in seed order), and the solo photo's ID. Callers
    /// are responsible for deleting the folder.
    private func seedBurstAndSolo(
        burstPrimary: SpeciesMatch
    ) throws -> (folder: URL, burstIDs: [UUID], soloID: UUID) {
        let folder = try makeTempFolder()
        let db = try ReportDatabase(folderPath: folder)

        let burstID = UUID()
        var burstIDs: [UUID] = []
        for i in 0..<3 {
            var p = makePhoto(folder: folder, filename: "burst_\(i).CR3")
            p.burstGroupID = burstID
            p.assignedSpecies = [burstPrimary]
            try db.save(&p)
            burstIDs.append(p.id)
        }

        var solo = makePhoto(folder: folder, filename: "solo.CR3")
        solo.assignedSpecies = [burstPrimary]
        try db.save(&solo)

        return (folder, burstIDs, solo.id)
    }
```

- [ ] **Step 2: Add the failing test for `setAssignedSpecies` fan-out**

Append this test just before the closing `}` of the `AssignedSpeciesTests` struct (after `speciesFilterMatchesAnyAssignedEntry`, around line 312):

```swift
    // MARK: - Burst fan-out

    @Test func setAssignedSpeciesFansOutToAllBurstMembers() throws {
        let seeded = try seedBurstAndSolo(
            burstPrimary: match(sci: "Aquila", common: "Eagle", ebird: "eagle")
        )
        defer { try? FileManager.default.removeItem(at: seeded.folder) }

        let appState = AppState()
        appState.loadPhotos(for: seeded.folder)

        // Edit the species list on ONE burst member; expect all three to
        // receive the new list while the solo photo stays untouched.
        let newList = [
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
            match(sci: "Buteo", common: "Buzzard", ebird: "buzzard"),
        ]
        appState.setAssignedSpecies(id: seeded.burstIDs[0], species: newList)

        let db = try ReportDatabase(folderPath: seeded.folder)
        for id in seeded.burstIDs {
            let fetched = try #require(try db.fetchPhoto(id: id))
            #expect(fetched.assignedSpecies.map(\.speciesID) == ["hawk", "buzzard"])
        }
        let solo = try #require(try db.fetchPhoto(id: seeded.soloID))
        #expect(solo.assignedSpecies.map(\.speciesID) == ["eagle"])
    }
```

- [ ] **Step 3: Run the test to verify it fails**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.setAssignedSpeciesFansOutToAllBurstMembers 2>&1 | tail -30
```

Expected: FAIL — the non-edited burst members still have `["eagle"]` because fan-out hasn't been implemented yet. The first `#expect(... == ["hawk", "buzzard"])` on `seeded.burstIDs[1]` or `[2]` reports a mismatch.

- [ ] **Step 4: Commit the red test**

```bash
git add apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift
git commit -m "test(species): red test for burst-wide setAssignedSpecies fan-out"
```

---

## Task 2: Implement `burstMemberIDs` helper and fan out `setAssignedSpecies`

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift` (add helper near the other private helpers; change `setAssignedSpecies` around line 400)

- [ ] **Step 1: Add the `burstMemberIDs(for:)` helper**

Open `apps/mac-client/SuperPickyApp/AppState.swift`. Immediately above the `private func mutatePhoto(...)` declaration (currently at line 289), insert:

```swift
    /// Return the photo IDs that should receive a species edit originated
    /// from `id`. For a photo whose `burstGroupID` is non-nil, this is the
    /// full set of burst members (in `allPhotos` order); otherwise it is
    /// just `[id]`. Species edits fan out across the whole burst so the
    /// sidebar, keywords, and sidecars stay consistent across frames that
    /// depict the same bird(s).
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

- [ ] **Step 2: Replace `setAssignedSpecies` with the fan-out version**

In the same file, replace the current body of `setAssignedSpecies(id:species:)` (currently at lines 400–405):

```swift
    func setAssignedSpecies(id: UUID, species: [SpeciesMatch]) {
        mutatePhoto(id: id) { photo in
            photo.assignedSpecies = species
        }
        buildSpeciesHierarchy()
    }
```

with:

```swift
    func setAssignedSpecies(id: UUID, species: [SpeciesMatch]) {
        for memberID in burstMemberIDs(for: id) {
            mutatePhoto(id: memberID) { photo in
                photo.assignedSpecies = species
            }
        }
        buildSpeciesHierarchy()
    }
```

- [ ] **Step 3: Run the new test to verify it passes**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.setAssignedSpeciesFansOutToAllBurstMembers 2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 4: Run the full `AssignedSpeciesTests` suite to confirm no regressions**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests 2>&1 | tail -30
```

Expected: PASS — every pre-existing test still green (solo-photo `setAssignedSpecies` paths unchanged because `burstMemberIDs` falls back to `[id]` when `burstGroupID` is nil).

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift
git commit -m "feat(species): fan setAssignedSpecies out to the whole burst"
```

---

## Task 3: Failing burst fan-out test for `correctSpecies`

**Files:**
- Test: `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`

- [ ] **Step 1: Add the failing test**

Append this test immediately after `setAssignedSpeciesFansOutToAllBurstMembers` (the test added in Task 1):

```swift
    @Test func correctSpeciesFansOutToAllBurstMembers() throws {
        let seeded = try seedBurstAndSolo(
            burstPrimary: match(sci: "Aquila chrysaetos",
                                common: "Bald Eagle", // deliberately wrong
                                ebird: "goleag")
        )
        defer { try? FileManager.default.removeItem(at: seeded.folder) }

        let appState = AppState()
        appState.loadPhotos(for: seeded.folder)

        appState.correctSpecies(id: seeded.burstIDs[0], commonName: "Golden Eagle")

        let db = try ReportDatabase(folderPath: seeded.folder)
        for id in seeded.burstIDs {
            let fetched = try #require(try db.fetchPhoto(id: id))
            let primary = try #require(fetched.assignedSpecies.first)
            #expect(primary.commonName == "Golden Eagle")
            // Stable identity preserved — sidebar bucket must not jump.
            #expect(primary.speciesID == "goleag")
            #expect(primary.scientificName == "Aquila chrysaetos")
        }
        let solo = try #require(try db.fetchPhoto(id: seeded.soloID))
        #expect(solo.assignedSpecies.first?.commonName == "Bald Eagle")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.correctSpeciesFansOutToAllBurstMembers 2>&1 | tail -30
```

Expected: FAIL — sibling burst members still have `commonName == "Bald Eagle"`.

- [ ] **Step 3: Commit the red test**

```bash
git add apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift
git commit -m "test(species): red test for burst-wide correctSpecies fan-out"
```

---

## Task 4: Fan out `correctSpecies`

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/AppState.swift` (change `correctSpecies` body around lines 360–394)

- [ ] **Step 1: Replace `correctSpecies` with the fan-out version**

In `apps/mac-client/SuperPickyApp/AppState.swift`, replace the current body of `correctSpecies(id:commonName:)`:

```swift
    func correctSpecies(id: UUID, commonName: String) {
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        mutatePhoto(id: id) { photo in
            var list = photo.assignedSpecies
            guard var first = list.first else {
                // No existing species — treat the rename as assigning a
                // new custom entry with `trimmed` as both scientific and
                // common name, so the photo leaves the Unidentified bucket.
                if !trimmed.isEmpty {
                    photo.assignedSpecies = [SpeciesMatch(
                        scientificName: trimmed,
                        commonName: trimmed,
                        confidence: 0,
                        cnName: nil,
                        pinyin: nil,
                        thresholdUsed: "manual",
                        ebirdCode: nil
                    )]
                }
                return
            }
            first = SpeciesMatch(
                scientificName: first.scientificName,
                commonName: trimmed.isEmpty ? nil : trimmed,
                confidence: first.confidence,
                cnName: first.cnName,
                pinyin: first.pinyin,
                thresholdUsed: first.thresholdUsed,
                ebirdCode: first.ebirdCode
            )
            list[0] = first
            photo.assignedSpecies = list
        }
        buildSpeciesHierarchy()
    }
```

with:

```swift
    func correctSpecies(id: UUID, commonName: String) {
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        for memberID in burstMemberIDs(for: id) {
            mutatePhoto(id: memberID) { photo in
                var list = photo.assignedSpecies
                guard var first = list.first else {
                    // No existing species — treat the rename as assigning a
                    // new custom entry with `trimmed` as both scientific and
                    // common name, so the photo leaves the Unidentified bucket.
                    if !trimmed.isEmpty {
                        photo.assignedSpecies = [SpeciesMatch(
                            scientificName: trimmed,
                            commonName: trimmed,
                            confidence: 0,
                            cnName: nil,
                            pinyin: nil,
                            thresholdUsed: "manual",
                            ebirdCode: nil
                        )]
                    }
                    return
                }
                first = SpeciesMatch(
                    scientificName: first.scientificName,
                    commonName: trimmed.isEmpty ? nil : trimmed,
                    confidence: first.confidence,
                    cnName: first.cnName,
                    pinyin: first.pinyin,
                    thresholdUsed: first.thresholdUsed,
                    ebirdCode: first.ebirdCode
                )
                list[0] = first
                photo.assignedSpecies = list
            }
        }
        buildSpeciesHierarchy()
    }
```

The inner closure body is intentionally unchanged — each burst member keeps its own `speciesID` / `scientificName` / `confidence` / `cnName` / `pinyin` / `thresholdUsed` / `ebirdCode`, only the primary `commonName` is rewritten. A member with an empty `assignedSpecies` still gets the new-custom-entry branch, which matches the spec.

- [ ] **Step 2: Run the new test to verify it passes**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.correctSpeciesFansOutToAllBurstMembers 2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 3: Run the full `AssignedSpeciesTests` suite**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests 2>&1 | tail -30
```

Expected: PASS for every test, including the pre-existing solo-photo cases (`correctSpeciesRenamesCommonNameWithoutChangingSpeciesID`, `correctSpeciesOnUnidentifiedPhotoCreatesCustomEntry`) because `burstMemberIDs` returns `[id]` when `burstGroupID` is nil.

- [ ] **Step 4: Commit**

```bash
git add apps/mac-client/SuperPickyApp/AppState.swift
git commit -m "feat(species): fan correctSpecies out to the whole burst"
```

---

## Task 5: Add solo-photo regression test, run full pre-commit gate

**Files:**
- Test: `apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift`

- [ ] **Step 1: Add an explicit solo-photo regression test**

Append immediately after `correctSpeciesFansOutToAllBurstMembers`:

```swift
    @Test func setAssignedSpeciesOnSoloPhotoDoesNotTouchOtherPhotos() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        let eagle = match(sci: "Aquila", common: "Eagle", ebird: "eagle")

        var solo = makePhoto(folder: folder, filename: "solo.CR3")
        solo.assignedSpecies = [eagle]
        try db.save(&solo)

        var other = makePhoto(folder: folder, filename: "other.CR3")
        other.assignedSpecies = [eagle]
        try db.save(&other)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = match(sci: "Accipiter", common: "Hawk", ebird: "hawk")
        appState.setAssignedSpecies(id: solo.id, species: [hawk])

        let db2 = try ReportDatabase(folderPath: folder)
        let soloAfter = try #require(try db2.fetchPhoto(id: solo.id))
        let otherAfter = try #require(try db2.fetchPhoto(id: other.id))
        #expect(soloAfter.assignedSpecies.map(\.speciesID) == ["hawk"])
        #expect(otherAfter.assignedSpecies.map(\.speciesID) == ["eagle"])
    }
```

This locks in the non-fan-out path: two photos with `burstGroupID == nil` must not affect each other even though they share a folder.

- [ ] **Step 2: Run the new solo test**

Run:

```bash
cd apps/mac-client && swift test --filter AssignedSpeciesTests.setAssignedSpeciesOnSoloPhotoDoesNotTouchOtherPhotos 2>&1 | tail -30
```

Expected: PASS.

- [ ] **Step 3: Run the full test suite twice to catch parallel-ordering flakes**

Per the project's memory ("Run tests before push" — twice if anything touches shared state). Run:

```bash
cd apps/mac-client && swift test 2>&1 | tail -20
```

Expected: PASS.

Run it again:

```bash
cd apps/mac-client && swift test 2>&1 | tail -20
```

Expected: PASS.

- [ ] **Step 4: Run the pre-commit gate (G1 static + L1)**

Run:

```bash
scripts/pre-commit.sh 2>&1 | tail -30
```

Expected: PASS (swift build + swiftlint + unit tests all green).

- [ ] **Step 5: Commit**

```bash
git add apps/mac-client/SuperPickyTests/Core/AssignedSpeciesTests.swift
git commit -m "test(species): lock in solo-photo non-fan-out regression"
```

---

## Out of scope (confirm in review)

- No changes to `mutatePhoto`, `ReportDatabase`, `Photo`, `XMPWriter`, or any UI view.
- No undo-stack changes — species edits are not tracked by undo today; fan-out will push one undo entry per member, but those entries only record `starRating` / `isPick` / `isManualRating` / `wasHidden` (unchanged by species mutation), so popping them is a no-op.
- No L3 XCUITest coverage this round — the species-edit XCUITests are currently flaky, per explicit guidance. Revisit after the underlying flakes are fixed.

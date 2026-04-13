# Culling Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the culling pipeline to a Lightroom-compatible 0–5 star workflow with manual overrides, zoom, XMP sidecar output, and one-click export of keepers.

**Architecture:** Extend the existing RatingEngine to produce 0–5 ratings using continuous signal thresholds. Add zoom/pan to both preview and fullscreen viewers via a shared ZoomableImageView. Write XMP sidecars using pure Swift XML generation. Export copies filtered photos + sidecars to a user-chosen folder.

**Tech Stack:** Swift/SwiftUI, GRDB, AppKit (NSOpenPanel), Foundation (FileManager)

---

## Status

| # | Commit | Description | Status |
|---|--------|-------------|--------|
| 1 | `docs: add culling enhancement plan` | This plan | done |
| 2 | `test: add 0-5 rating engine tests (TDD)` | Tests for new rating scale | pending |
| 3 | `feat: implement 0-5 rating engine (TDD)` | New rating logic | pending |
| 4 | `feat: update UI for 0-5 star scale` | StarRatingView, SourceListView, InfoBarView | pending |
| 5 | `feat: add isManualRating column + migration` | Database migration | pending |
| 6 | `feat: wire manual rating in fullscreen viewer` | Keyboard 0-5 rating | pending |
| 7 | `feat: skip manual ratings during reprocessing` | Pipeline respects overrides | pending |
| 8 | `test: add ZoomableImageView tests (TDD)` | Zoom state logic tests | pending |
| 9 | `feat: implement ZoomableImageView` | Zoom/pan image component | pending |
| 10 | `feat: integrate zoom into preview and fullscreen` | Replace static image views | pending |
| 11 | `test: add XMP writer tests (TDD)` | XMP output validation | pending |
| 12 | `feat: implement XMPWriter` | XMP sidecar generation | pending |
| 13 | `test: add ExportService tests (TDD)` | Export logic tests | pending |
| 14 | `feat: implement ExportService` | Copy + XMP export | pending |
| 15 | `feat: add Export button and wire to UI` | Toolbar button + progress | pending |

---

## Background

SuperPicky rates bird photos on a 0–3 scale using sharpness (eye visibility proxy) and aesthetics scores. The user's Lightroom workflow uses 0–5 stars. Manual rating override is stubbed. There's no way to export keepers or write metadata for Lightroom import. The preview has no zoom — critical for evaluating sharpness.

---

## Delivery Goal

**Setup:**
```bash
cd apps/mac-client && swift build
```

**Run:**
```bash
cd apps/mac-client && swift test
```

**Verify:**
1. `swift test` — all tests pass (existing + new)
2. `swift build` — compiles without warnings
3. Launch app, process a folder — photos get 0–5 star ratings
4. In fullscreen, press `0`–`5` keys — rating updates immediately, shows pencil icon
5. Reprocess same folder — manual ratings are preserved
6. Double-click or press `Z` on preview — toggles 100% zoom; scroll to zoom, drag to pan
7. Click "Export" toolbar button — folder picker appears, copies filtered photos + .xmp sidecars
8. Open exported .xmp in text editor — contains valid XMP with rating, species keywords, flight tag

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Rating scale | 0–5 Int (no -1) | Matches Lightroom; -1 becomes 0 (reject) for undetected birds |
| Zoom implementation | Custom SwiftUI view with GeometryReader + magnification gesture | No AppKit dependency needed; works in both preview and fullscreen |
| XMP generation | Pure Swift string template | No external dependencies; XMP schema is simple and stable |
| Export mechanism | FileManager.copyItem | Simple, reliable; no need for NSFileCoordinator for one-shot copy |
| Manual rating flag | `isManualRating` Bool column | Lightweight; pipeline checks before overwriting |
| Zoom state | Shared `ZoomState` ObservableObject | Reused between preview and fullscreen without duplication |

---

## Technical Design

### Data Model Changes

**Photo model** — `starRating` range changes from -1..3 to 0..5. Add `isManualRating: Bool`.

```swift
// Photo.swift — changes only
var starRating: Int      // was -1..3, now 0..5
var isManualRating: Bool // NEW — default false
```

**Database migration v2:**
```sql
ALTER TABLE photos ADD COLUMN isManualRating BOOLEAN NOT NULL DEFAULT 0;
-- Re-map existing ratings: -1 → 0, 1..3 stay (will be re-rated on next process)
UPDATE photos SET starRating = 0 WHERE starRating = -1;
```

### RatingEngine — New Logic

```
Input: detected, confidence, sharpness, aesthetics, allKeypointsHidden,
       isOverexposed, isUnderexposed, isFlying, focusSharpnessWeight, focusAestheticsWeight, config

moderateSharpness = (minimumSharpness + config.sharpnessThreshold) / 2
moderateAesthetics = (minimumAesthetics + config.aestheticsThreshold) / 2

adjSharpness = sharpness * focusSharpnessWeight * (isFlying ? 1.2 : 1.0)
adjAesthetics = (aesthetics ?? 0) * focusAestheticsWeight * (isFlying ? 1.1 : 1.0)

if !detected → 0
if confidence < 0.5 → 0
if sharpness < minimumSharpness → 0
if aesthetics < minimumAesthetics → 0
if allKeypointsHidden → 1
if adjSharpness < moderateSharpness AND adjAesthetics < moderateAesthetics → 1
if adjSharpness < moderateSharpness OR adjAesthetics < moderateAesthetics → 2
if adjSharpness < threshold AND adjAesthetics < threshold → 3
if adjSharpness >= threshold AND adjAesthetics >= threshold → 5
else → 4

Exposure penalty: rating = max(0, rating - 1) if overexposed or underexposed

isPick = (finalRating == 5)
```

### ZoomableImageView

```
State: scale (CGFloat, default 1.0), offset (CGSize, default .zero), isFittedToView (Bool, default true)

Gestures:
- MagnificationGesture: multiply scale, clamp to 0.5..10.0
- DragGesture: update offset (only when scale > 1.0)
- Double-click / Z key: toggle between fit-to-view (scale=1.0) and 100% (scale = imagePixelWidth / viewWidth)
- Scroll wheel: increment/decrement scale by 0.1 per tick

Reset: when photo changes, reset to fit-to-view
```

### XMP Sidecar Format

```xml
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
      xmp:Rating="{rating}">
      <dc:subject>
        <rdf:Bag>
          {<rdf:li>{species common name}</rdf:li> if identified}
          {<rdf:li>{species scientific name}</rdf:li> if identified}
          {<rdf:li>In Flight</rdf:li> if isFlying}
        </rdf:Bag>
      </dc:subject>
      <lr:hierarchicalSubject>
        <rdf:Bag>
          {<rdf:li>Bird|{common name}</rdf:li> if identified}
          {<rdf:li>Behavior|In Flight</rdf:li> if isFlying}
        </rdf:Bag>
      </lr:hierarchicalSubject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
```

### ExportService

```
func export(photos: [Photo], to destination: URL, onProgress: (Int, Int) -> Void) throws -> ExportResult

For each photo:
1. Write XMP sidecar next to original (source folder) — XMPWriter.write(photo:)
2. Copy original file to destination
3. Copy .xmp file to destination
4. Report progress

ExportResult: exported count, skipped count (already exists), failed count, errors
```

---

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| No bird detected | Rating = 0 (was -1, now mapped to 0) |
| Aesthetics is nil | Treated as 0 for comparison |
| Manual rating then reprocess | Manual rating preserved, AI skips |
| Export with no photos matching filter | Alert: "No photos match the current filter" |
| Export file already exists in destination | Skip file, increment skip count |
| Export disk full | Catch error, report partial results with error message |
| Export cancelled by user | Stop iteration, report partial export count |
| Zoom beyond image bounds | Clamp offset to keep image visible |
| XMP special characters in species name | XML-escape: &, <, >, ", ' |
| Photo has no species and is not flying | XMP has rating only, empty keyword bags |
| Existing database with old -1 ratings | Migration maps -1 → 0 |
| User presses rating key with no photo selected | No-op |

---

## File Inventory

### Files Changed

| # | File | Op | Description |
|---|------|----|-------------|
| 1 | `apps/mac-client/SuperPickyApp/RatingEngine.swift` | modify | 0–5 rating logic with moderate thresholds |
| 2 | `apps/mac-client/SuperPickyTests/Core/RatingEngineTests.swift` | modify | Rewrite tests for 0–5 scale |
| 3 | `apps/mac-client/SuperPickyApp/Photo.swift` | modify | Add `isManualRating` property |
| 4 | `apps/mac-client/SuperPickyApp/ReportDatabase.swift` | modify | v2 migration for isManualRating + remap -1 ratings |
| 5 | `apps/mac-client/SuperPickyTests/Data/ReportDatabaseTests.swift` | modify | Test migration and new column |
| 6 | `apps/mac-client/SuperPickyApp/StarRatingView.swift` | modify | Display 0–5 stars |
| 7 | `apps/mac-client/SuperPickyApp/SourceListView.swift` | modify | Sidebar ratings 5,4,3,2,1,0 with new labels/colors |
| 8 | `apps/mac-client/SuperPickyApp/PreviewView.swift` | modify | Replace InfoBarView star display, add manual indicator |
| 9 | `apps/mac-client/SuperPickyApp/FullscreenViewer.swift` | modify | Wire 0–5 key handlers, add database write |
| 10 | `apps/mac-client/SuperPickyApp/MainView.swift` | modify | Pass database to fullscreen, add Export button, update AppState |
| 11 | `apps/mac-client/SuperPickyApp/ThumbnailStripView.swift` | modify | StarRatingView already uses `rating` param — just works with 0–5 |
| 12 | `apps/mac-client/SuperPickyApp/PipelineCoordinator.swift` | modify | Skip rating for isManualRating photos |
| 13 | `apps/mac-client/SuperPickyApp/CullingConfig.swift` | modify | No changes needed — thresholds drive 4/5 boundary naturally |
| 14 | `apps/mac-client/SuperPickyApp/ZoomableImageView.swift` | create | Zoomable/pannable image component |
| 15 | `apps/mac-client/SuperPickyApp/XMPWriter.swift` | create | XMP sidecar file generation |
| 16 | `apps/mac-client/SuperPickyApp/ExportService.swift` | create | Export photos + sidecars to folder |
| 17 | `apps/mac-client/SuperPickyTests/Core/XMPWriterTests.swift` | create | XMP output validation tests |
| 18 | `apps/mac-client/SuperPickyTests/Core/ExportServiceTests.swift` | create | Export logic tests |
| 19 | `apps/mac-client/SuperPickyTests/Core/ZoomStateTests.swift` | create | Zoom state logic tests |

### Files NOT Changed (and why)

| File | Reason |
|------|--------|
| `python-server/*` | No new endpoints needed — all changes are client-side |
| `apps/mac-client/SuperPickyApp/BurstDetector.swift` | Burst logic unchanged |
| `apps/mac-client/SuperPickyApp/ExposureDetector.swift` | Exposure detection unchanged |
| `apps/mac-client/SuperPickyApp/CullingConfig.swift` | Thresholds drive the 4/5 boundary naturally — no changes needed |

---

## Test Plan

### L1 — Unit Tests

| # | Test | What It Validates |
|---|------|-------------------|
| 1 | `noBirdDetected → rating 0` | Undetected birds get 0 (not -1) |
| 2 | `lowConfidence → rating 0` | Confidence gate still works |
| 3 | `belowMinimumSharpness → rating 0` | Floor gate works |
| 4 | `belowMinimumAesthetics → rating 0` | Floor gate works |
| 5 | `allKeypointsHidden → rating 1` | Hidden keypoints cap at 1 |
| 6 | `bothBelowModerate → rating 1` | Low signals = poor |
| 7 | `oneBelowModerate → rating 2` | Mixed low = below average |
| 8 | `bothModerateButBelowThreshold → rating 3` | Moderate signals = average |
| 9 | `oneAboveThreshold → rating 4` | One strong signal = good |
| 10 | `bothAboveThreshold → rating 5` | Both strong = excellent |
| 11 | `exposurePenalty reduces by 1` | Overexposure drops rating |
| 12 | `flyingBonus lifts below-threshold to above` | Flight adjustments work |
| 13 | `isPick true only at rating 5` | Pick flag semantics |
| 14 | `XMP with rating and species` | Correct XML output |
| 15 | `XMP with no species no flight` | Rating-only XMP |
| 16 | `XMP escapes special characters` | &, <, > in species names |
| 17 | `ExportService copies files to destination` | Files appear in dest folder |
| 18 | `ExportService skips existing files` | No overwrite, skip count incremented |
| 19 | `ExportService writes XMP sidecars` | .xmp files created alongside copies |
| 20 | `ZoomState toggleFitActualPixels` | Scale toggles between 1.0 and actual |
| 21 | `ZoomState clampScale` | Scale stays within 0.5–10.0 |
| 22 | `ZoomState resetOnPhotoChange` | State resets when photo changes |
| 23 | `Database migration adds isManualRating` | Column exists after migration |
| 24 | `Database migration remaps -1 to 0` | Old ratings updated |

---

## Tasks

### Task 1: 0–5 Star Rating Engine

Rewrite RatingEngine to produce 0–5 ratings using moderate thresholds. Update all existing tests to match new scale.

**Acceptance criteria:**
- [ ] `RatingEngine.calculate()` returns ratings 0–5 per the new logic
- [ ] `isPick` is true only when final rating is 5
- [ ] No bird detected returns 0 (not -1)
- [ ] All 13 rating tests pass
- [ ] `swift test` passes with no regressions

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 2 | test | `test: add 0-5 rating engine tests (TDD)` | `SuperPickyTests/Core/RatingEngineTests.swift` |
| 3 | feat | `feat: implement 0-5 rating engine (TDD)` | `SuperPickyApp/RatingEngine.swift` |

### Task 2: UI Updates for 0–5 Stars + Database Migration

Update StarRatingView to show 5 stars. Update SourceListView sidebar to list ratings 5–0 with new labels. Add `isManualRating` column via database migration. Remap old -1 ratings to 0. Update Photo model.

**Acceptance criteria:**
- [ ] StarRatingView renders 5 stars with correct fill
- [ ] SourceListView shows ratings 5,4,3,2,1,0 with labels (Excellent, Good, Average, Below Average, Poor, Reject)
- [ ] Database v2 migration adds `isManualRating` column
- [ ] Existing -1 ratings become 0 after migration
- [ ] Photo model has `isManualRating: Bool` defaulting to false
- [ ] `swift build` compiles; `swift test` passes

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 4 | feat | `feat: add isManualRating column + database migration` | `Photo.swift`, `ReportDatabase.swift`, `ReportDatabaseTests.swift` |
| 5 | feat | `feat: update UI for 0-5 star scale` | `StarRatingView.swift`, `SourceListView.swift`, `PreviewView.swift` |

### Task 3: Manual Rating Override

Wire keyboard shortcuts 0–5 in FullscreenViewer to persist rating to database. Show manual indicator in InfoBarView. Pipeline skips photos with isManualRating=true during reprocessing.

**Acceptance criteria:**
- [ ] Pressing 0–5 in fullscreen sets rating and persists to database
- [ ] `isManualRating` set to true when user rates manually
- [ ] InfoBarView shows pencil icon when rating is manual
- [ ] PipelineCoordinator skips rating assignment for isManualRating=true photos
- [ ] `swift build` compiles; `swift test` passes

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 6 | feat | `feat: wire manual rating in fullscreen viewer` | `FullscreenViewer.swift`, `MainView.swift`, `PreviewView.swift` |
| 7 | feat | `feat: skip manual ratings during reprocessing` | `PipelineCoordinator.swift` |

### Task 4: Zoomable Image View

Create a ZoomableImageView with scroll-to-zoom, drag-to-pan, double-click/Z-key toggle between fit and 100%. Integrate into PreviewView and FullscreenViewer.

**Acceptance criteria:**
- [ ] Scroll wheel zooms in/out (0.5x–10x range)
- [ ] Drag pans the image when zoomed past 1.0x
- [ ] Double-click toggles between fit-to-view and 100%
- [ ] Z key toggles between fit-to-view and 100%
- [ ] State resets when selected photo changes
- [ ] Works in both main preview and fullscreen viewer
- [ ] `swift build` compiles; `swift test` passes

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 8 | test | `test: add ZoomState tests (TDD)` | `SuperPickyTests/Core/ZoomStateTests.swift` |
| 9 | feat | `feat: implement ZoomableImageView` | `SuperPickyApp/ZoomableImageView.swift` |
| 10 | feat | `feat: integrate zoom into preview and fullscreen` | `PreviewView.swift`, `FullscreenViewer.swift` |

### Task 5: XMP Sidecar Writer

Create XMPWriter that generates valid XMP sidecar files with star rating, species keywords, and flight tags.

**Acceptance criteria:**
- [ ] XMP contains `xmp:Rating` with correct value
- [ ] Keywords include species common name, scientific name (if identified)
- [ ] Keywords include "In Flight" if photo.isFlying
- [ ] Hierarchical keywords use `Bird|name` and `Behavior|In Flight` format
- [ ] Special characters in species names are XML-escaped
- [ ] Sidecar file named `{original-stem}.xmp`
- [ ] `swift test` passes

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 11 | test | `test: add XMP writer tests (TDD)` | `SuperPickyTests/Core/XMPWriterTests.swift` |
| 12 | feat | `feat: implement XMPWriter` | `SuperPickyApp/XMPWriter.swift` |

### Task 6: Export Service + UI

Create ExportService that copies filtered photos + XMP sidecars to a destination folder. Add "Export" toolbar button with folder picker, progress sheet, and completion alert.

**Acceptance criteria:**
- [ ] Export button visible in toolbar
- [ ] Clicking Export opens NSOpenPanel for folder selection
- [ ] All photos matching current filter are exported
- [ ] For each photo: XMP written to source, original + XMP copied to destination
- [ ] Progress shown during export
- [ ] Completion alert shows count ("Exported 47 photos to /path")
- [ ] Existing files in destination are skipped
- [ ] Empty filter shows "No photos match the current filter" alert
- [ ] `swift build` compiles; `swift test` passes

**Commits:**
| # | Type | Message | Files |
|---|------|---------|-------|
| 13 | test | `test: add ExportService tests (TDD)` | `SuperPickyTests/Core/ExportServiceTests.swift` |
| 14 | feat | `feat: implement ExportService` | `SuperPickyApp/ExportService.swift` |
| 15 | feat | `feat: add Export button and wire to UI` | `MainView.swift`, `ContentView` section in `MainView.swift` |

---

## Commit Sequence

| # | Task | Type | Message | Depends On |
|---|------|------|---------|------------|
| 1 | — | docs | `docs: add culling enhancement plan` | — |
| 2 | 1 | test | `test: add 0-5 rating engine tests (TDD)` | 1 |
| 3 | 1 | feat | `feat: implement 0-5 rating engine (TDD)` | 2 |
| 4 | 2 | feat | `feat: add isManualRating column + database migration` | 3 |
| 5 | 2 | feat | `feat: update UI for 0-5 star scale` | 4 |
| 6 | 3 | feat | `feat: wire manual rating in fullscreen viewer` | 5 |
| 7 | 3 | feat | `feat: skip manual ratings during reprocessing` | 6 |
| 8 | 4 | test | `test: add ZoomState tests (TDD)` | 7 |
| 9 | 4 | feat | `feat: implement ZoomableImageView` | 8 |
| 10 | 4 | feat | `feat: integrate zoom into preview and fullscreen` | 9 |
| 11 | 5 | test | `test: add XMP writer tests (TDD)` | 10 |
| 12 | 5 | feat | `feat: implement XMPWriter` | 11 |
| 13 | 6 | test | `test: add ExportService tests (TDD)` | 12 |
| 14 | 6 | feat | `feat: implement ExportService` | 13 |
| 15 | 6 | feat | `feat: add Export button and wire to UI` | 14 |

### Dependency Graph

```
1 (plan)
└─ 2 (task 1: rating tests)
   └─ 3 (task 1: rating implementation)
      └─ 4 (task 2: DB migration)
         └─ 5 (task 2: UI updates)
            └─ 6 (task 3: manual rating)
               └─ 7 (task 3: pipeline skip)
                  └─ 8 (task 4: zoom tests)
                     └─ 9 (task 4: zoom implementation)
                        └─ 10 (task 4: zoom integration)
                           └─ 11 (task 5: XMP tests)
                              └─ 12 (task 5: XMP implementation)
                                 └─ 13 (task 6: export tests)
                                    └─ 14 (task 6: export implementation)
                                       └─ 15 (task 6: export UI)
```

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| SwiftUI MagnificationGesture not available on macOS < 13 | low | App already requires macOS 14+ per existing SwiftUI usage |
| XMP not recognized by Lightroom | medium | Use exact Adobe namespace URIs; test with real Lightroom import |
| Large folder export (1000+ RAW files) slow | low | Progress indicator keeps user informed; sequential copy is fine |
| Database migration on large .report.db | low | ALTER TABLE + UPDATE is fast for <100k rows |

---

## Out of Scope

- Real sharpness measurement (Laplacian variance) — separate future improvement
- Batch rating operations (select multiple, rate all) — can be added later
- Custom signal weighting in settings — current fixed logic is sufficient
- CoreML inference — remains HTTP server for now
- Focus point detection — column exists but still unpopulated

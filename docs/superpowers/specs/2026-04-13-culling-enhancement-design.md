# Culling Enhancement — Design Spec

## Goal

Upgrade the culling pipeline from a rough 0–3 AI triage to a Lightroom-compatible 0–5 star workflow with manual overrides, XMP sidecar output, and one-click export of keepers.

## User Workflow

1. AI processes folder → assigns 0–5 star ratings using granular scoring
2. User reviews in fullscreen, adjusts ratings with `0–5` keys
3. User filters to keepers (e.g., 4+ stars)
4. User clicks "Export" → originals + XMP sidecars copied to destination folder
5. User imports destination folder into Lightroom — ratings and keywords appear automatically

## Acceptance Criteria

1. Photos are rated 0–5 stars by the AI, using the full range meaningfully
2. User can press `0–5` keys in fullscreen viewer to override any photo's rating; override persists across reprocessing
3. XMP sidecar files are written with star rating, species keywords, and behavioral tags (e.g., "In Flight")
4. Lightroom correctly reads star ratings and keywords from generated XMP files
5. "Export" button copies all photos matching the current sidebar filter to a user-chosen folder, with XMP sidecars
6. Export shows progress and a completion summary
7. All existing tests continue to pass; new features have unit tests

---

## Feature 1: 0–5 Star Rating Scale

### Current State

- `RatingEngine.swift` produces ratings -1 to 3
- `Photo` model stores `starRating: Int`
- Sharpness is `bestEyeVisibility * 600` (proxy)
- Logic: `sharpHigh && aestheticsHigh → 3`, `sharpHigh || aestheticsHigh → 2`, else `1`
- Flight bonus: sharpness × 1.2, aesthetics × 1.1
- Exposure penalty: rating -= 1
- Fixed minimums: sharpness 100, aesthetics 2.0

### New Rating Logic

| Stars | Meaning | Conditions |
|-------|---------|------------|
| 0 | Reject | No bird detected, below fixed minimums (sharpness < 100 or aesthetics < 2.0), or detection confidence < 0.5 |
| 1 | Poor | Bird detected but all keypoints hidden, or both signals well below thresholds |
| 2 | Below average | One signal somewhat passable, other weak |
| 3 | Average | Both signals above minimums but below configured thresholds |
| 4 | Good | One signal above threshold, other at least moderate (above midpoint between minimum and threshold) |
| 5 | Excellent | Both sharpness AND aesthetics above configured thresholds |

**Modifiers** (applied after base rating):
- Flight bonus: adjusted sharpness × 1.2, adjusted aesthetics × 1.1 (before threshold comparison)
- Exposure penalty: -1 star (floor at 0) if overexposed or underexposed

**`isPick`**: true when final rating == 5

### Scoring Detail

To use the full range meaningfully, define a "moderate" midpoint:
- `moderateSharpness = (minimumSharpness + sharpnessThreshold) / 2`
- `moderateAesthetics = (minimumAesthetics + aestheticsThreshold) / 2`

Logic (after applying flight bonus, before exposure penalty):
```
if no bird or below minimums or confidence < 0.5 → 0
else if all keypoints hidden → 1
else if sharpness < moderate AND aesthetics < moderate → 1
else if sharpness < moderate OR aesthetics < moderate → 2
else if sharpness < threshold AND aesthetics < threshold → 3
else if sharpness >= threshold AND aesthetics >= threshold → 5
else → 4  (one above threshold, one moderate-to-threshold)
```

Then apply exposure penalty: `rating = max(0, rating - 1)` if overexposed or underexposed.

### Changes

- `RatingEngine.swift`: Rewrite `calculateRating()` with new logic
- `Photo` model: `starRating` range becomes 0–5 (type stays `Int`, no migration needed for the column itself)
- `ReportDatabase.swift`: Migration to update any existing data (re-rate on next process)
- `CullingConfig.swift`: Skill level presets updated for 0–5 context (thresholds stay the same — they drive the boundary between 4 and 5)
- UI: All star displays updated to show 0–5 (SourceListView sidebar filters, ThumbnailStripView, InfoBarView)

---

## Feature 2: Manual Rating Override

### Behavior

- In fullscreen viewer (`FullscreenViewer.swift`), pressing `0–5` sets the current photo's star rating
- The override is persisted immediately to the database
- A new `isManualRating: Bool` column (default false) tracks whether the rating was manually set
- When reprocessing a folder, photos with `isManualRating == true` keep their manual rating (AI does not overwrite)
- Visual indicator in the info bar when a rating is manually set (e.g., a small pencil icon or "Manual" label)

### Changes

- `FullscreenViewer.swift`: Wire `rateSelected()` to write to database
- `ReportDatabase.swift`: Add `isManualRating` column, migration
- `PipelineCoordinator.swift`: Skip rating assignment for photos with `isManualRating == true`
- `InfoBarView.swift`: Show manual indicator

---

## Feature 3: XMP Sidecar Writing

### XMP Structure

Standard Adobe XMP with Dublin Core and Lightroom namespaces:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description
      xmlns:xmp="http://ns.adobe.com/xap/1.0/"
      xmlns:dc="http://purl.org/dc/elements/1.1/"
      xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
      xmp:Rating="4">
      <dc:subject>
        <rdf:Bag>
          <rdf:li>Bald Eagle</rdf:li>
          <rdf:li>In Flight</rdf:li>
        </rdf:Bag>
      </dc:subject>
      <lr:hierarchicalSubject>
        <rdf:Bag>
          <rdf:li>Bird|Bald Eagle</rdf:li>
          <rdf:li>Behavior|In Flight</rdf:li>
        </rdf:Bag>
      </lr:hierarchicalSubject>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
```

### Keywords Written

- Species common name (e.g., "Bald Eagle") — if identified
- Species scientific name (e.g., "Haliaeetus leucocephalus") — if identified
- "In Flight" — if `isFlying == true`
- Hierarchical: `Bird|<common name>`, `Behavior|In Flight`

### Sidecar Naming

Matches the original filename with `.xmp` extension:
- `IMG_1234.CR3` → `IMG_1234.xmp`
- `DSC_5678.NEF` → `DSC_5678.xmp`

### Changes

- New `XMPWriter.swift`: Pure Swift, no external dependencies. Takes a `Photo` record, produces XMP string, writes to disk next to the original file.

---

## Feature 4: Export Picks

### Behavior

1. "Export" button in the main toolbar (always visible)
2. Clicking it opens a folder picker (NSOpenPanel in directory mode)
3. All photos matching the **current sidebar filter** are exported:
   - If user has filtered to "4+ stars" in sidebar, only those are exported
   - If no filter, all photos are exported (with confirmation warning)
4. For each photo:
   a. Write/update XMP sidecar next to the original (source folder)
   b. Copy original RAW file to destination folder
   c. Copy XMP sidecar to destination folder
5. Progress sheet shows: "Exporting 12 of 47..." with progress bar
6. Completion alert: "Exported 47 photos to /path/to/folder"

### Edge Cases

- Destination folder doesn't exist: create it
- File already exists in destination: skip with warning count in summary
- Export with no photos matching filter: show "No photos match the current filter"
- User cancels during export: stop, report partial results
- Disk full: catch error, report which file failed

### Changes

- New `ExportService.swift`: Handles file copy + XMP write + progress reporting
- `MainView.swift`: Add "Export" toolbar button
- `ContentView.swift` or `MainView.swift`: Wire button to ExportService with current filter

---

## What Doesn't Change

- Python server (no new endpoints)
- Burst detection algorithm
- Exposure detection algorithm
- Species identification
- Bird detection pipeline
- Sharpness proxy (remains eye-visibility-based — a separate future improvement)
- AVONET geographic filter
- GPS/Apple Maps integration

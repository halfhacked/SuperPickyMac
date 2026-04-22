# Changelog

## v0.0.3 — 2026-04-21
### Architecture
- **Native CoreML inference** — all 5 endpoints (flight, keypoints, YOLO bird detection/segmentation, OSEA species, aesthetics) run in-process via CoreML. The Python server is gone; no HTTP, no venv, no `install.sh`.
- **Model weights download on first launch** (~350 MB) — bundled `.mlmodelc` scaffolds; only `weight.bin` fetched at startup with live progress and failure recovery
- **ARM64-only build** — drops x86_64 support in exchange for smaller binary and faster builds

### New Features
- **Species edit panel** — multi-species assignment with searchable candidate list, pinyin-initials shorthand, primary/secondary reordering
- **Burst-inherit species** — identified siblings fan species across the whole burst, including unidentified frames
- **Reverse-geocoding + GPS-aware species filter** — cascading chain (GPS cell → country → global) with Avonet species filter, 6.5× throughput via GPS-cell cache
- **Recursive directory scan** — folder roots with nested subdirectories now fully ingested
- **Auto-resume processing** on app startup when a folder has un-processed files
- **Refresh Folder** / **Reprocess Folder** context-menu actions (preserves manual ratings)
- **Threshold calibrator** — live popover in the main view; tune thresholds and preview predictions before committing
- **Species sort dropdown** — default alphabetical, opt-in sort by photo count
- **Processed/total count** in each folder row
- **Full-res preview preload** — Lightroom-style upgrade after 400 ms dwell; true 100% zoom decodes full RAW on demand
- **Keyword / XMP writing** — IPTC keywords written via exiftool, species edits fan out to burst siblings

### Performance
- 6-way concurrent ML pipeline (`maxConcurrentMLWork` 3→6); **877 ARW processed in 27 s (~32 photos/s)** on M-series GPU
- OSEA + Flight + Keypoints moved to `.cpuAndGPU` compute unit
- Write-behind DB + XMP off the critical path
- Reverse-geocoding (`CLGeocoder`) moved off the ML critical path onto a write-behind chain
- Pre-warm SpeciesFilter Avonet cache for unique GPS cells ahead of ML work
- Thread GPS from EXIF pre-pass directly into identify; no redundant file open
- Fold `ImageProperties.load` into `RAWConverter.decode` (single source open)
- Dedupe thumbnail decode + parallelize EXIF pre-pass
- 3× large-folder ingest by removing O(n) main-thread work
- O(1) photo lookup in `AppState` (fixes scroll lag in big folders)
- Smart square bird crop + bilinear resize kills flight false positives
- Feed YOLO + OSEA a 1280 thumbnail instead of full-res RAW

### UX
- **Settings redesign** — inline descriptions on non-obvious controls, Processing tab removed, aligned slider rows
- **Info panel** merges species editor + EXIF reader with Lightroom-style grouped layout; GPS row links to Apple Maps pushpin
- **Non-burst thumbnails dimmed** in strip while viewing a burst photo
- **Cancel / fast-path cancellation** — Stop button feels instant
- **Multi-level undo** — 20-action ring buffer
- **Delete to Trash** (`⌫` with confirmation)
- **Keyboard shortcut help overlay** (`?` key)
- **Compare view** — zoom/pan with independent-side navigation and lock toggle
- **Export All Visible** — exports the filtered set, not just picks
- Multiple processed folders persist across launches; sidebar counts derived from `allPhotos` so they can't drift
- `Z` key toggles 100% zoom at mouse position; drag pan speed matches zoom level
- Dark theme throughout preview/content; no more white flash on photo switch

### Fixes
- Species sidebar: burst appears under every tagged species (#34)
- DB v8 migration passes id through as `DatabaseValue`, not `String`
- Rebuild species hierarchy on cancel/refresh too, not just success
- Localize species edit panel headers and candidate levels
- Full codebase localization sweep via SwiftLint enforcement
- Preview: fall back to full decode when source is smaller than target; don't swap displayed image to full-res mid-render

### Code Quality
- Parity test harness — Swift pipeline vs Python reference across top-5, distribution, bbox, pinyin, GPS-filter
- Migrated to xcodegen (xcodeproj is generated, not tracked)
- Dropped legacy `SkillLevel` preset abstraction; thresholds exposed directly
- Extract `SpeciesAssignmentEditor`, `PhotoRatingPredictor`, `SpeciesHierarchyBuilder`, pure EXIFReader / ExifPanel / XMP keyword helpers for unit testability
- Python server code fully removed; conversion scripts moved to `tools/model-conversion/`
- Git LFS for model weight `.bin` files

## v0.0.2 — 2026-04-15
### Fixed
- FullscreenViewer info bar was never visible (showInfo default was false)
- Burst detection ignored the `burstDetectionEnabled` setting
- AppState.mutatePhoto silently swallowed errors, leaving DB and UI out of sync

### Performance
- **Real sharpness scoring** — Laplacian variance on bird crop replaces eye-visibility proxy
- O(n²) species hierarchy rebuild eliminated during incremental processing
- Preview image cache (5 images / 200 MB) avoids repeated RAW decodes on navigation
- BurstDetector Vision runs off the cooperative thread pool (`Task.detached`)
- ThumbnailCache memory cost limit (50 MB, pixel-accurate cost calculation)
- Static `DateFormatter` in BurstDetector (was re-instantiated per photo)

### UX
- Sort thumbnail strip by filename, date, rating, sharpness, or aesthetics score
- Cancel button during folder processing
- Zoom / pan in CompareView with independent-side arrow navigation and lock toggle
- 20-action multi-level undo (ring buffer)
- Export now respects the active star / burst / picks filter
- Multiple processed folders persist across launches
- Filter bar no longer resets when new photos arrive while processing
- Keyboard shortcut help overlay (`?` key)

### New Features
- Delete photo to Trash (`⌫` with confirmation dialog)
- Reprocess Folder context-menu action (preserves manually-rated photos)
- Export All Visible — exports the currently filtered set, not just picks
- Manual species correction — double-click the species label in the info bar to edit

### Code Quality
- Removed dead `birdBbox` / `birdMask` / `focusPointStatus` DB columns (DB migration v3)
- Removed dead `focusSharpnessWeight` / `focusAestheticsWeight` parameters
- Developer paths gated behind `#if DEBUG`
- Structured logging via `os.Logger` throughout AppState
- Deleted unused `ProcessingSheet.swift`
- Deduplicated test helpers into shared `TestImageHelpers.swift`

## v0.0.1 — 2026-04-14
### Added
- Initial project scaffold

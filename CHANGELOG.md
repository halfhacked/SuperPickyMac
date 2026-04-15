# Changelog

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

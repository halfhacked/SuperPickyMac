# SuperPicky Mac

Native macOS app for AI-powered bird photo culling.

## Architecture

- Swift/SwiftUI frontend (all UI + business logic)
- Python HTTP server (model inference only — 5 endpoints)
- GRDB for SQLite persistence
- Vision/Accelerate/Core Image for image processing

## Quality System

| Layer | What | Command | Trigger |
|-------|------|---------|---------|
| G1 Static | swift build + flake8 | `scripts/pre-commit.sh` | pre-commit |
| L1 Unit | Swift Testing + pytest (mocked) | `scripts/pre-commit.sh` | pre-commit |
| L2 Integration | Swift ↔ real Python server | `scripts/run-l2.sh` | pre-push |
| G2 Security | gitleaks | `scripts/gate-security.sh` | pre-push |
| L3 BDD | XCUITest full user flows | `scripts/run-l3.sh` | on-demand |

## Port Convention

| Environment | Port |
|-------------|------|
| Dev | 8420 |
| L2 Integration | 18420 |
| L3 BDD | 28420 |

## Common Commands

```bash
# Build
cd apps/mac-client && swift build

# Test
cd apps/mac-client && swift test

# Python server (dev)
cd python-server && python superpicky_server.py --port 8420

# Python server tests
cd python-server && pytest tests/ -v
```

## Key Decisions

- InferenceClient protocol abstracts Python HTTP vs future CoreML
- One .report.db per processed folder
- Python server is inference-only — no business logic
- All business logic (rating, burst, exposure, sharpness) in Swift
- CullingConfig is @MainActor @Observable (UI state)
- Fixed minimums (sharpness 100, aesthetics 2.0) separate from configurable thresholds
- Species identification delegated to preen package (birdpreen on PyPI) — server sends file path, preen handles image loading, YOLO, crop, OSEA classify, GPS filtering
- Keyboard shortcuts use NSEvent.addLocalMonitorForEvents (not SwiftUI .onKeyPress which requires focus)
- Vertical scroll wheel on horizontal ScrollView uses NSEvent monitor + NSScrollView responder chain walk

## Retrospective

- **xcodebuild silently uses stale binaries after edits**: When editing Swift files via automation tools, xcodebuild's incremental build sometimes doesn't detect changes. → The Edit tool's atomic writes may not update mtime reliably from Xcode's dependency tracker perspective. → Always `touch` changed files or delete `Build/Intermediates.noindex/SuperPicky.build/` before `xcodebuild build`. SPM (`swift build`) always picks up changes correctly.

- **New Swift files must be added to both Package.swift AND the .xcodeproj**: SPM build and xcodebuild use different file registries. A file that compiles with `swift build` will fail `xcodebuild` (used by XCUITests and CI) if not in the pbxproj. → When creating any new .swift file, immediately add it to the Xcode project's PBXBuildFile, PBXFileReference, PBXGroup children, and PBXSourcesBuildPhase sections. CI catches this — always check CI after adding files.

- **SwiftUI .onKeyPress requires view focus, which is fragile**: After clicking a thumbnail, sidebar, or any other view, keyboard focus moves away from ContentView and .onKeyPress stops working. → Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` for global keyboard shortcuts that should work regardless of focus. Check `firstResponder is NSTextView` to skip text fields.

- **SwiftUI ScrollView(.horizontal) does not respond to vertical scroll wheel**: The vertical scroll wheel events are consumed by the scroll view but silently dropped since there's no vertical axis. NSView `.background()` or `.overlay()` approaches don't intercept because the scroll view consumes events first. → Use `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to intercept at the app level, then walk the responder chain to find the NSScrollView and manually scroll it. Cache the NSScrollView reference.

- **CGImageSourceCreateThumbnailFromImageIfAbsent vs Always**: `IfAbsent` returns the embedded preview JPEG (~1616px for Sony ARW) which is fast but low-res. `Always` decodes the full RAW which is slow but full-res. For zoom, the preview looks blurry — must use `CGImageSourceCreateImageAtIndex` for actual full-resolution decode. → Use `IfAbsent` for initial fast display, upgrade to `CreateImageAtIndex` on demand when user zooms past 1x.

- **Zoom-at-point coordinate space must match the ZoomableImageView exactly**: `onContinuousHover` on a parent container (e.g., PreviewView which includes InfoBarView) reports coordinates in the container's space, not the image view's space. The InfoBar height causes Y-axis drift. → Always attach hover tracking directly to the view that receives `.scaleEffect` and `.offset`, not a parent wrapper.

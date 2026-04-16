# SuperPicky Mac

Native macOS app for AI-powered bird photo culling.

## Architecture

- Swift/SwiftUI frontend (all UI + business logic)
- CoreML inference in-process — all 5 endpoints native, no server required
  - Flight classifier: EfficientNet-B3 (`FlightModel.swift`)
  - Keypoint detector: ResNet50 PartLocalizer (`KeypointModel.swift`)
  - Bird detection: YOLO11l-seg (`YOLOBirdDetector.swift`)
  - Species ID: OSEA classifier (`OSEAClassifier.swift`)
  - Aesthetics: CFANet/TOPIQ (`AestheticsModel.swift`)
- GRDB for SQLite persistence
- Vision/Accelerate/Core Image for image processing
- Model conversion scripts: `tools/model-conversion/` (requires `~/projects/SuperPicky/models/`)

## Quality System

| Layer | What | Command | Trigger |
|-------|------|---------|---------|
| G1 Static | swift build + swiftlint | `scripts/pre-commit.sh` | pre-commit |
| L1 Unit | Swift Testing | `scripts/pre-commit.sh` | pre-commit |
| L2 Parity | CoreML parity harness (Swift) | `scripts/run-l2.sh` | pre-push |
| G2 Security | gitleaks | `scripts/gate-security.sh` | pre-push |
| L3 BDD | XCUITest full user flows (TEST_MODE=1) | `scripts/run-l3.sh` | on-demand |

## Common Commands

```bash
# Build
cd apps/mac-client && swift build

# Test
cd apps/mac-client && swift test

# Re-convert CoreML models (requires ~/projects/SuperPicky/models/)
python3 tools/model-conversion/convert_flight.py
python3 tools/model-conversion/convert_keypoint.py
python3 tools/model-conversion/convert_yolo.py
python3 tools/model-conversion/convert_osea.py
python3 tools/model-conversion/convert_topiq.py
```

## Key Decisions

- CoreML is the sole inference backend — no Python server, no HTTP client
- One .report.db per processed folder
- All business logic (rating, burst, exposure, sharpness) in Swift
- CoreML model weights download on first launch (~350 MB); subsequent launches are fully offline
- CullingConfig is @MainActor @Observable (UI state)
- Fixed minimums (sharpness 100, aesthetics 2.0) separate from configurable thresholds
- Keyboard shortcuts use NSEvent.addLocalMonitorForEvents (not SwiftUI .onKeyPress which requires focus)
- Vertical scroll wheel on horizontal ScrollView uses NSEvent monitor + NSScrollView responder chain walk

## Retrospective

- **xcodebuild silently uses stale binaries after edits**: When editing Swift files via automation tools, xcodebuild's incremental build sometimes doesn't detect changes. → The Edit tool's atomic writes may not update mtime reliably from Xcode's dependency tracker perspective. → Always `touch` changed files or delete `Build/Intermediates.noindex/SuperPicky.build/` before `xcodebuild build`. SPM (`swift build`) always picks up changes correctly.

- **New Swift files must be added to both Package.swift AND the .xcodeproj**: SPM build and xcodebuild use different file registries. A file that compiles with `swift build` will fail `xcodebuild` (used by XCUITests and CI) if not in the pbxproj. → When creating any new .swift file, immediately add it to the Xcode project's PBXBuildFile, PBXFileReference, PBXGroup children, and PBXSourcesBuildPhase sections. CI catches this — always check CI after adding files.

- **SwiftUI .onKeyPress requires view focus, which is fragile**: After clicking a thumbnail, sidebar, or any other view, keyboard focus moves away from ContentView and .onKeyPress stops working. → Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` for global keyboard shortcuts that should work regardless of focus. Check `firstResponder is NSTextView` to skip text fields.

- **SwiftUI ScrollView(.horizontal) does not respond to vertical scroll wheel**: The vertical scroll wheel events are consumed by the scroll view but silently dropped since there's no vertical axis. NSView `.background()` or `.overlay()` approaches don't intercept because the scroll view consumes events first. → Use `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to intercept at the app level, then walk the responder chain to find the NSScrollView and manually scroll it. Cache the NSScrollView reference.

- **CGImageSourceCreateThumbnailFromImageIfAbsent vs Always**: `IfAbsent` returns the embedded preview JPEG (~1616px for Sony ARW) which is fast but low-res. `Always` decodes the full RAW which is slow but full-res. For zoom, the preview looks blurry — must use `CGImageSourceCreateImageAtIndex` for actual full-resolution decode. → Use `IfAbsent` for initial fast display, upgrade to `CreateImageAtIndex` on demand when user zooms past 1x.

- **Zoom-at-point coordinate space must match the ZoomableImageView exactly**: `onContinuousHover` on a parent container (e.g., PreviewView which includes InfoBarView) reports coordinates in the container's space, not the image view's space. The InfoBar height causes Y-axis drift. → Always attach hover tracking directly to the view that receives `.scaleEffect` and `.offset`, not a parent wrapper.

- **When a feature "doesn't work," verify the data exists before debugging the UI**: Adding Chinese species names (`speciesCnName`) to the UI showed English names even after extensive localization debugging (Bundle swizzling, onChange vs task(id:), cross-window observation). The actual problem: the DB column was added via migration but photos were never reprocessed, so `speciesCnName` was NULL for every row. → Before debugging display logic, always `SELECT` the relevant column from the DB to confirm the data exists. A 5-second SQL query would have saved hours of UI debugging.

- **For runtime language switching in SwiftUI, let views read the language and compute display values — don't rebuild data**: Attempted to rebuild `speciesEntries` when language changed via `onChange`/`task(id:)` on `MainView`, but these didn't fire reliably when the change originated from the Settings window (separate Scene). → Store all language variants in the data model (e.g., `name` + `cnName`), then have the view read `config.appLanguage` (an `@Observable` property) and pick the right value at render time. SwiftUI automatically re-renders when the observed property changes — no manual rebuild needed.

- **SwiftUI runtime localization has three separate mechanisms for three UI layers**: (1) `.environment(\.locale)` handles `Text("literal")` via `LocalizedStringKey` — works for SwiftUI views but NOT for AppKit-rendered elements like `Settings` scene tab labels or the menu bar. (2) `config.localized("key")` (explicit Bundle lookup reading `appLanguage`) handles tab labels and interpolated strings — works because reading `@Observable` property triggers SwiftUI re-render. (3) `NSApp.mainMenu` title iteration handles the menu bar — must be done programmatically since it's pure AppKit. → When localizing menu items at runtime, cache the original English title on first encounter (`ObjectIdentifier` → original title), then always look up from the English key. Otherwise switching back fails because the key is now the translated string.

- **`@Observable` `onChange` and `didSet` are unreliable through `@Bindable` bindings**: `onChange(of: config.property)` attached to a view using `@Bindable var config = config` fires inconsistently — sometimes only once, sometimes never. `didSet` on `@Observable` properties also only fires once through `@Bindable`. → Use `task(id: config.property)` on a stable parent view instead. It fires on every id change, including initial appear, and isn't affected by child view recreation cycles.

- **SPM `swift build` doesn't embed `.lproj` resources into `Bundle.main` properly**: SPM puts resources in a separate `_ModuleName.bundle` with lowercased directory names (`zh-hans.lproj` instead of `zh-Hans.lproj`). `.environment(\.locale)` and `Bundle.main.path(forResource:)` don't find them. → Use `xcodebuild` (via xcodegen) for builds that need localization. It places `.lproj` directories in the app bundle's `Contents/Resources/` with correct casing.

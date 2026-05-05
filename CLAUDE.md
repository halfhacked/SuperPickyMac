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
| G1 Static | xcodebuild build + swiftlint | `scripts/pre-commit.sh` | pre-commit |
| L1 Unit | Swift Testing via xcodebuild | `scripts/pre-commit.sh` | pre-commit |
| L2 Parity | Python reference vs Swift output | `scripts/parity/run.sh` | manual |
| G2 Security | gitleaks | `scripts/gate-security.sh` | pre-push |
| L3 BDD | XCUITest full user flows (TEST_MODE=1) | `scripts/run-l3.sh` | on-demand |

## Common Commands

```bash
# Build
cd app && xcodebuild build -scheme SuperPicky -destination 'platform=macOS'

# Test (L1 unit)
cd app && xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests

# Re-convert CoreML models (requires ~/projects/SuperPicky/models/)
python3 tools/model-conversion/convert_flight.py
python3 tools/model-conversion/convert_keypoint.py
python3 tools/model-conversion/convert_yolo.py
python3 tools/model-conversion/convert_osea.py
python3 tools/model-conversion/convert_topiq.py
```

Adding a new `.swift` file requires registering it in `SuperPicky.xcodeproj/project.pbxproj` (PBXBuildFile, PBXFileReference, PBXGroup children, PBXSourcesBuildPhase) — there is no Package.swift or xcodegen to regenerate it from.

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

- **XCUITest gotchas on the shared-app UI tests** (Calibrator/CompareView/CullingWorkflow/KeyboardHelp):
  - **LazyHStack items past the viewport aren't in the a11y tree.** `ThumbnailStripView` lazy-renders; `app.images["Thumbnail_DSC0XXXX.jpg"]` returns "no matches" for photos not currently visible, even if the photo exists in the folder. Use `selectThumbnail`'s `arrowStripUntil` to arrow-key through the strip and force lazy instantiation before asserting existence.
  - **Fixture decode time varies CI vs local by 5–10×.** CI's macOS runner lags heavily on full-res JPG/ARW decode; a test that's snappy locally can time out a 15 s `waitForExistence` in CI. Don't use `_ = element.waitForExistence(timeout:)` in setUp — always `XCTAssertTrue(...)` on the return so silent timeouts become loud failures at the real source instead of cryptic downstream "no matches" errors.
  - **`PhotoPreview` only enters the a11y tree once the auto-selected photo has finished its full-res decode** — wait for it specifically in setUp (see `XCUIApplication.waitUntilProcessed`), not for `images.firstMatch` (which matches any thumbnail and fires early).
  - **When clicking an element to clear text-field focus, tolerate its absence.** `arrowStripUntil` falls back to `typeKey(.escape)` when PhotoPreview isn't in the tree — the NSEvent global monitor picks up arrow keys regardless, so the click is a focus-clearing hint, not a hard dependency.
  - **Accessibility identifiers live in `A11y.swift`** (UI test target). Mirror any new `.accessibilityIdentifier(...)` in app code there; drift between app and tests silently produces "no matches" failures.

- **xcodebuild silently uses stale binaries after edits**: When editing Swift files via automation tools, xcodebuild's incremental build sometimes doesn't detect changes. → The Edit tool's atomic writes may not update mtime reliably from Xcode's dependency tracker perspective. → Always `touch` changed files or delete `Build/Intermediates.noindex/SuperPicky.build/` before `xcodebuild build`.

- **SwiftUI .onKeyPress requires view focus, which is fragile**: After clicking a thumbnail, sidebar, or any other view, keyboard focus moves away from ContentView and .onKeyPress stops working. → Use `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` for global keyboard shortcuts that should work regardless of focus. Check `firstResponder is NSTextView` to skip text fields.

- **SwiftUI ScrollView(.horizontal) does not respond to vertical scroll wheel**: The vertical scroll wheel events are consumed by the scroll view but silently dropped since there's no vertical axis. NSView `.background()` or `.overlay()` approaches don't intercept because the scroll view consumes events first. → Use `NSEvent.addLocalMonitorForEvents(matching: .scrollWheel)` to intercept at the app level, then walk the responder chain to find the NSScrollView and manually scroll it. Cache the NSScrollView reference.

- **CGImageSourceCreateThumbnailFromImageIfAbsent vs Always**: `IfAbsent` returns the embedded preview JPEG (~1616px for Sony ARW) which is fast but low-res. `Always` decodes the full RAW which is slow but full-res. For zoom, the preview looks blurry — must use `CGImageSourceCreateImageAtIndex` for actual full-resolution decode. → Use `IfAbsent` for initial fast display, upgrade to `CreateImageAtIndex` on demand when user zooms past 1x.

- **Zoom-at-point coordinate space must match the ZoomableImageView exactly**: `onContinuousHover` on a parent container (e.g., PreviewView which includes InfoBarView) reports coordinates in the container's space, not the image view's space. The InfoBar height causes Y-axis drift. → Always attach hover tracking directly to the view that receives `.scaleEffect` and `.offset`, not a parent wrapper.

- **When a feature "doesn't work," verify the data exists before debugging the UI**: Adding Chinese species names (`speciesCnName`) to the UI showed English names even after extensive localization debugging (Bundle swizzling, onChange vs task(id:), cross-window observation). The actual problem: the DB column was added via migration but photos were never reprocessed, so `speciesCnName` was NULL for every row. → Before debugging display logic, always `SELECT` the relevant column from the DB to confirm the data exists. A 5-second SQL query would have saved hours of UI debugging.

- **For runtime language switching in SwiftUI, let views read the language and compute display values — don't rebuild data**: Attempted to rebuild `speciesEntries` when language changed via `onChange`/`task(id:)` on `MainView`, but these didn't fire reliably when the change originated from the Settings window (separate Scene). → Store all language variants in the data model (e.g., `name` + `cnName`), then have the view read `config.appLanguage` (an `@Observable` property) and pick the right value at render time. SwiftUI automatically re-renders when the observed property changes — no manual rebuild needed.

- **SwiftUI runtime localization has three separate mechanisms for three UI layers**: (1) `.environment(\.locale)` handles `Text("literal")` via `LocalizedStringKey` — works for SwiftUI views but NOT for AppKit-rendered elements like `Settings` scene tab labels or the menu bar. (2) `config.localized("key")` (explicit Bundle lookup reading `appLanguage`) handles tab labels and interpolated strings — works because reading `@Observable` property triggers SwiftUI re-render. (3) `NSApp.mainMenu` title iteration handles the menu bar — must be done programmatically since it's pure AppKit. → When localizing menu items at runtime, cache the original English title on first encounter (`ObjectIdentifier` → original title), then always look up from the English key. Otherwise switching back fails because the key is now the translated string.

- **`@Observable` `onChange` and `didSet` are unreliable through `@Bindable` bindings**: `onChange(of: config.property)` attached to a view using `@Bindable var config = config` fires inconsistently — sometimes only once, sometimes never. `didSet` on `@Observable` properties also only fires once through `@Bindable`. → Use `task(id: config.property)` on a stable parent view instead. It fires on every id change, including initial appear, and isn't affected by child view recreation cycles.

# Reveal in Finder context menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a right-click context menu with a single "Reveal in Finder" item to thumbnail strip cells and the main preview, so the user can jump from the app to the photo's parent folder in Finder with the file selected.

**Architecture:** Extract a tiny `FinderReveal` helper (protocol + enum) so both call sites share one line and the L1 test can swap the AppKit call for a fake. Attach `.contextMenu` to `ThumbnailCell` and to `AsyncPreviewImage` inside `PreviewView`. Add an `A11y.revealInFinderMenuItem` identifier so XCUITests can address the menu item.

**Tech Stack:** Swift / SwiftUI, AppKit (`NSWorkspace.activateFileViewerSelecting`), Swift Testing for L1, XCUITest for L3.

**Spec:** `docs/superpowers/specs/2026-05-04-reveal-in-finder-context-menu-design.md`

**Working directory for all commands:** `apps/mac-client/` (so `xcodebuild` finds the `.xcodeproj`).

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/mac-client/SuperPickyApp/FinderReveal.swift` | new | `FinderRevealer` protocol + `SystemFinderRevealer` + `FinderReveal` static API |
| `apps/mac-client/SuperPickyTests/FinderRevealTests.swift` | new | L1 Swift Testing — verifies `FinderReveal.reveal(_:)` calls injected revealer with the photo's URL |
| `apps/mac-client/SuperPickyApp/ThumbnailStripView.swift` | modify | Add `@Environment(CullingConfig.self)` + `.contextMenu` on `ThumbnailCell` |
| `apps/mac-client/SuperPickyApp/PreviewView.swift` | modify | Add `.contextMenu` on `AsyncPreviewImage` inside `if let photo` arm |
| `apps/mac-client/SuperPickyUITests/A11y.swift` | modify | Add `revealInFinderMenuItem` identifier |
| `apps/mac-client/SuperPickyUITests/CullingWorkflowUITests.swift` | modify | Two new test methods: thumbnail right-click + preview right-click |
| `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj` | modify | Register `FinderReveal.swift` (app target) and `FinderRevealTests.swift` (test target) — 4 entries each |

No new `.strings` keys: `"Reveal in Finder"` is already used at `MainView.swift:207`, so en + zh-Hans entries already exist. (Verify in Task 1.)

---

## Task 1: Verify localization key exists

**Files:** read-only check — no edits.

- [ ] **Step 1: Confirm `Reveal in Finder` is in both `.strings` files**

Run: `grep -n "Reveal in Finder" apps/mac-client/SuperPickyApp/*.lproj/*.strings`

Expected: at least one match in `en.lproj/Localizable.strings` and one in `zh-Hans.lproj/Localizable.strings`. If missing in either, add the entry there before continuing — copy the surrounding format of neighboring keys.

- [ ] **Step 2: No commit (read-only).**

---

## Task 2: `FinderReveal` helper (TDD)

**Files:**
- Create: `apps/mac-client/SuperPickyApp/FinderReveal.swift`
- Create: `apps/mac-client/SuperPickyTests/FinderRevealTests.swift`
- Modify: `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj` (register both files)

- [ ] **Step 1: Write the failing L1 test**

Create `apps/mac-client/SuperPickyTests/FinderRevealTests.swift`:

```swift
import Testing
import Foundation
@testable import SuperPicky

@MainActor
struct FinderRevealTests {
    final class RecordingRevealer: FinderRevealer {
        var recorded: [URL] = []
        func reveal(_ urls: [URL]) {
            recorded.append(contentsOf: urls)
        }
    }

    @Test
    func revealsPhotoFilePathAsURL() {
        let original = FinderReveal.revealer
        defer { FinderReveal.revealer = original }

        let fake = RecordingRevealer()
        FinderReveal.revealer = fake

        let photo = Photo(
            filename: "test.arw",
            filePath: "/tmp/superpicky/test.arw",
            folderPath: "/tmp/superpicky"
        )
        FinderReveal.reveal(photo)

        #expect(fake.recorded == [URL(fileURLWithPath: "/tmp/superpicky/test.arw")])
    }
}
```

`Photo`'s designated init is `Photo(id: UUID = UUID(), filename: String, filePath: String, folderPath: String, dateCreated: Date = Date())` (see `SuperPickyApp/Photo.swift:63`); existing tests use the three-arg form (e.g. `SuperPickyTests/Core/PhotoSelectionTests.swift:9`).

- [ ] **Step 2: Run test to verify it fails to compile**

Run from `apps/mac-client/`:

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/FinderRevealTests 2>&1 | tail -40
```

Expected: build error mentioning `FinderReveal` / `FinderRevealer` not found, OR test target doesn't include `FinderRevealTests.swift` (we register in Step 4).

- [ ] **Step 3: Create the implementation**

Create `apps/mac-client/SuperPickyApp/FinderReveal.swift`:

```swift
import AppKit
import Foundation

/// Protocol seam so unit tests can swap the AppKit call for a fake
/// without launching Finder during the test run.
protocol FinderRevealer {
    func reveal(_ urls: [URL])
}

struct SystemFinderRevealer: FinderRevealer {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Reveals a photo in Finder with the file selected. Both right-click
/// surfaces (thumbnail strip, main preview) call into this single API.
@MainActor
enum FinderReveal {
    static var revealer: FinderRevealer = SystemFinderRevealer()

    static func reveal(_ photo: Photo) {
        revealer.reveal([URL(fileURLWithPath: photo.filePath)])
    }
}
```

- [ ] **Step 4: Register both new files in `project.pbxproj`**

Open `apps/mac-client/SuperPicky.xcodeproj/project.pbxproj`. For each new `.swift` file, add four entries. Use `uuidgen | tr -d '-' | head -c 24` to mint UUIDs, or hand-pick 24-hex-char IDs that don't already appear in the file.

For `FinderReveal.swift` (app target — pattern mirrors `SourceListView.swift` per its 4 entries at lines 289 / 507 / 847 / 1635):

1. **PBXBuildFile section** (with the other `... in Sources */` entries near line 289):
   ```
   <NEW_BUILD_UUID> /* FinderReveal.swift in Sources */ = {isa = PBXBuildFile; fileRef = <NEW_FILE_REF_UUID> /* FinderReveal.swift */; };
   ```
2. **PBXFileReference section** (with the other `*.swift` file refs near line 507):
   ```
   <NEW_FILE_REF_UUID> /* FinderReveal.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = FinderReveal.swift; sourceTree = "<group>"; };
   ```
3. **PBXGroup `SuperPickyApp` children** (the alphabetic-ish list of `.swift` siblings near line 847):
   ```
   <NEW_FILE_REF_UUID> /* FinderReveal.swift */,
   ```
4. **PBXSourcesBuildPhase for the app target** (the long `in Sources` list near line 1635):
   ```
   <NEW_BUILD_UUID> /* FinderReveal.swift in Sources */,
   ```

Repeat the four-entry pattern for `FinderRevealTests.swift` against the **test target**, mirroring `PreviewCacheTests.swift` (lines 162 / 629 / 740 / 1520 — confirm by `grep -n PreviewCacheTests project.pbxproj`).

- [ ] **Step 5: Build to confirm pbxproj edits are well-formed**

```bash
touch SuperPickyApp/FinderReveal.swift SuperPickyTests/FinderRevealTests.swift
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If the parse fails (e.g. duplicate UUID, missing brace), the error mentions `project.pbxproj` — fix and retry.

- [ ] **Step 6: Run the L1 test to confirm it passes**

```bash
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests/FinderRevealTests 2>&1 | tail -20
```

Expected: `Test Suite 'FinderRevealTests' passed`.

- [ ] **Step 7: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac
git add apps/mac-client/SuperPickyApp/FinderReveal.swift \
        apps/mac-client/SuperPickyTests/FinderRevealTests.swift \
        apps/mac-client/SuperPicky.xcodeproj/project.pbxproj
git commit -m "feat(reveal): FinderReveal helper + L1 test"
```

---

## Task 3: A11y identifier for the menu item

**Files:**
- Modify: `apps/mac-client/SuperPickyUITests/A11y.swift`

- [ ] **Step 1: Add the identifier**

In `A11y.swift`, after the existing `static let selectionCounter = "SelectionCounter"` line (around line 14), add:

```swift
    static let revealInFinderMenuItem = "RevealInFinder"
```

- [ ] **Step 2: Build to verify it compiles**

```bash
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac
git add apps/mac-client/SuperPickyUITests/A11y.swift
git commit -m "feat(reveal): A11y id for Reveal in Finder menu item"
```

---

## Task 4: Right-click on thumbnails

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/ThumbnailStripView.swift`

- [ ] **Step 1: Inject `CullingConfig` into `ThumbnailCell`**

In `ThumbnailStripView.swift`, inside `struct ThumbnailCell: View` (currently starts around line 91), add this property right after `let isDimmed: Bool`:

```swift
    @Environment(CullingConfig.self) private var config
```

- [ ] **Step 2: Add the context menu**

Still in `ThumbnailCell.body`, after the existing `.accessibilityValue(a11ySelectionValue)` line (currently the last modifier, around line 169), append:

```swift
        .contextMenu {
            Button {
                FinderReveal.reveal(photo)
            } label: {
                Label(config.localized("Reveal in Finder"), systemImage: "folder")
            }
            .accessibilityIdentifier(A11y.revealInFinderMenuItem)
        }
```

Note: `A11y` lives in the UI test target, so the identifier string `"RevealInFinder"` cannot be referenced by name from the app target. Use the literal string in the app code:

```swift
            .accessibilityIdentifier("RevealInFinder")
```

(Identifier is mirrored — not imported — exactly like every other entry in `A11y.swift` per the comment at the top of that file.)

- [ ] **Step 3: Touch + build**

```bash
touch SuperPickyApp/ThumbnailStripView.swift
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac
git add apps/mac-client/SuperPickyApp/ThumbnailStripView.swift
git commit -m "feat(reveal): right-click Reveal in Finder on thumbnail strip"
```

---

## Task 5: Right-click on the main preview

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PreviewView.swift`

- [ ] **Step 1: Add the context menu to `AsyncPreviewImage`**

In `PreviewView.swift`, inside `var body` of `struct PreviewView`, find the `if let photo {` arm (around line 19). The `AsyncPreviewImage(...)` chain currently ends with `.background(GeometryReader { ... })`. Append `.contextMenu` after that `.background`:

```swift
                AsyncPreviewImage(filePath: photo.filePath,
                                  zoomState: zoomState,
                                  brightnessAdjustment: brightnessAdjustment,
                                  sharpnessOverlayPhoto: showSharpnessOverlay ? photo : nil)
                    .accessibilityIdentifier("PhotoPreview")
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase { mouseInView = loc }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { viewSize = geo.size }
                            .onChange(of: geo.size) { _, s in viewSize = s }
                    })
                    .contextMenu {
                        Button {
                            FinderReveal.reveal(photo)
                        } label: {
                            Label(config.localized("Reveal in Finder"), systemImage: "folder")
                        }
                        .accessibilityIdentifier("RevealInFinder")
                    }
```

`config` is already in scope via `@Environment(CullingConfig.self) private var config` at the top of `PreviewView` — no new bindings needed.

- [ ] **Step 2: Touch + build**

```bash
touch SuperPickyApp/PreviewView.swift
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac
git add apps/mac-client/SuperPickyApp/PreviewView.swift
git commit -m "feat(reveal): right-click Reveal in Finder on main preview"
```

---

## Task 6: L3 XCUITests

**Files:**
- Modify: `apps/mac-client/SuperPickyUITests/CullingWorkflowUITests.swift`

The test class uses sequential `testNN_` numbering grouped by category (see header comment in the file). Categories used: 01-09 UI, 10-19 keyboard, 20-29 filter/counter, 30-39 export, 40-49 species. Use **50-59 for the new "context menu" group**.

- [ ] **Step 1: Add both tests at the end of the class (before the final `}`)**

```swift
    // MARK: - 50-59: Context menu

    func test50_ThumbnailRightClick_RevealInFinderMenuItemExists() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview must be visible before right-clicking thumbnails")

        // Pick the first thumbnail in the strip — must arrow into view
        // first so LazyHStack instantiates it (per A11y rule on lazy strips).
        let firstThumbnail = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'Thumbnail_'")).firstMatch
        XCTAssertTrue(firstThumbnail.waitForExistence(timeout: 5),
                      "At least one thumbnail must exist")

        firstThumbnail.rightClick()

        let menuItem = app.menuItems[A11y.revealInFinderMenuItem]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Reveal in Finder menu item should appear on right-click")

        // Dismiss without invoking — clicking would launch Finder during CI.
        app.typeKey(.escape, modifierFlags: [])
    }

    func test51_PreviewRightClick_RevealInFinderMenuItemExists() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview must be visible")

        preview.rightClick()

        let menuItem = app.menuItems[A11y.revealInFinderMenuItem]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3),
                      "Reveal in Finder menu item should appear on right-click")

        app.typeKey(.escape, modifierFlags: [])
    }
```

- [ ] **Step 2: Do NOT run XCUITests locally**

Per the project's testing policy (CLAUDE.md "Do not run XCUITest suites locally") these run on CI only. Skip the local run; CI will execute on push.

- [ ] **Step 3: Commit**

```bash
cd /Users/dazhen/projects/SuperPickyMac
git add apps/mac-client/SuperPickyUITests/CullingWorkflowUITests.swift
git commit -m "test(reveal): L3 XCUITests for thumbnail + preview right-click"
```

---

## Task 7: Final verification

- [ ] **Step 1: Clean build + L1 test pass**

From `apps/mac-client/`:

```bash
xcodebuild build -scheme SuperPicky -destination 'platform=macOS' 2>&1 | tail -5
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests 2>&1 | tail -20
```

Expected: build succeeds; the entire `SuperPickyTests` suite (including the new `FinderRevealTests`) passes.

- [ ] **Step 2: Run pre-commit script**

From repo root:

```bash
cd /Users/dazhen/projects/SuperPickyMac
./scripts/pre-commit.sh 2>&1 | tail -20
```

Expected: green (build + swiftlint + L1 unit). If swiftlint flags anything in the new code, fix and amend the most recent task's commit (do NOT amend earlier commits — make a new fix commit).

- [ ] **Step 3: Manual smoke (optional, non-blocking)**

Open the app, right-click a thumbnail, confirm the menu appears with "Reveal in Finder" (en) / "在 Finder 中显示" (zh-Hans depending on the .strings entry — confirm what's there in Task 1). Click it → Finder opens with the photo highlighted. Repeat on the main preview.

This is a sanity check only — the L1 + L3 tests cover the regression surface.

- [ ] **Step 4: Push (no merge)**

```bash
git push
```

Then watch CI per the "Watch CI until green" memory rule.

---

## Out of scope (do NOT implement)

- Multi-select reveal (right-click acts on the photo under the cursor only).
- Keyboard shortcut binding (⌘⇧R) — future work.
- "Open With…" submenu, "Show Package Contents", etc.
- Right-click on any surface other than `ThumbnailCell` and `AsyncPreviewImage`.

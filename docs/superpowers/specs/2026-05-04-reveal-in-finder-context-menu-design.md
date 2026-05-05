# Reveal in Finder — right-click context menu

**Status:** approved
**Date:** 2026-05-04

## Goal

Let the user right-click a photo in SuperPicky and jump straight to its location in Finder, with the file highlighted. Mirrors the standard macOS "Reveal in Finder" behavior found in Lightroom, Photos, and Finder itself.

## Surfaces

Two right-click surfaces, both showing the same single-item menu:

1. **Thumbnail strip cells** (`ThumbnailStripView.swift` → `ThumbnailCell`).
2. **Main preview image** (`PreviewView.swift` → the `AsyncPreviewImage` inside `if let photo`).

The menu acts on the photo under the cursor, not on the active selection. This matches Lightroom/Finder: right-click on a non-active thumbnail reveals *that* photo, not the currently-displayed one.

## Behavior

- Single menu item, label `Reveal in Finder` (localized key already exists in the codebase per `MainView.swift:207`).
- Selecting it calls `NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.filePath)])`.
  - This opens the parent folder *and* highlights the file. The existing call in `MainView.swift:208` uses `selectFile(nil, inFileViewerRootedAtPath:)`, which only opens the folder — not what we want here.
- No keyboard shortcut. (Future addition could bind ⌘⇧R, out of scope for this spec.)

## Implementation

### Shared helper

New file `apps/mac-client/SuperPickyApp/FinderReveal.swift`. Rule-of-two: two call sites (thumbnail + preview) is the trigger to extract.

The AppKit call sits behind a tiny protocol seam so the L1 test can swap in a fake without launching Finder during the test run:

```swift
protocol FinderRevealer {
    func reveal(_ urls: [URL])
}

struct SystemFinderRevealer: FinderRevealer {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

@MainActor
enum FinderReveal {
    static var revealer: FinderRevealer = SystemFinderRevealer()
    static func reveal(_ photo: Photo) {
        revealer.reveal([URL(fileURLWithPath: photo.filePath)])
    }
}
```

Both call sites use `FinderReveal.reveal(photo)`.

### ThumbnailCell

Attach `.contextMenu` to the `ThumbnailCell` body (after the existing `.accessibilityValue(...)` modifier). The cell already captures `photo: Photo`, so the closure has what it needs.

```swift
.contextMenu {
    Button(config.localized("Reveal in Finder"), systemImage: "folder") {
        FinderReveal.reveal(photo)
    }
}
```

`ThumbnailCell` does not currently have access to `CullingConfig`. Inject via `@Environment(CullingConfig.self) private var config` like sibling views do.

### PreviewView

Attach `.contextMenu` to the `AsyncPreviewImage` block inside the `if let photo` arm of `PreviewView.body`. The view already has `config` in scope.

```swift
AsyncPreviewImage(...)
    .accessibilityIdentifier("PhotoPreview")
    .onContinuousHover { ... }
    .background(...)
    .contextMenu {
        Button(config.localized("Reveal in Finder"), systemImage: "folder") {
            FinderReveal.reveal(photo)
        }
    }
```

## Localization

`Reveal in Finder` key is already used at `MainView.swift:207`, so en + zh-Hans strings exist. No new `.strings` entries required. Verify on the planning step by grepping the `.lproj` files.

## Accessibility

- The context menu items inherit standard SwiftUI a11y. To make the L3 test addressable, mirror the menu-item identifier in `A11y.swift` — e.g. `static let revealInFinderMenuItem = "RevealInFinder"`, attached via `.accessibilityIdentifier(A11y.revealInFinderMenuItem)` on the menu `Button`.

## Tests

### L1 (Swift Testing)

In `SuperPickyTests`, add a small test that swaps `FinderReveal.revealer` for a recording fake, calls `FinderReveal.reveal(photo)`, and asserts the recorded URL equals `URL(fileURLWithPath: photo.filePath)`. Restores the original revealer in teardown.

### L3 (XCUITest)

Add to existing `CullingWorkflowUITests` class (per "Group XCUITests" memory rule). Two cases:

1. `test_thumbnail_rightClick_showsRevealInFinder()` — right-click a known thumbnail (use `arrowStripUntil` to materialize it lazily first per LazyHStack rule), assert the menu item with id `RevealInFinder` exists, dismiss with Escape. Do not click it (would launch Finder during CI).
2. `test_preview_rightClick_showsRevealInFinder()` — right-click `images["PhotoPreview"]`, assert menu item exists, dismiss.

Both tests must `XCTAssertTrue` on every `waitForExistence` call (per "waitForExistence silent timeout" memory).

Right-click in XCUITest: `element.rightClick()` (works on macOS).

### Out of scope for tests

- No test that actually triggers Finder. Asserting menu *visibility* is sufficient; the helper's URL correctness is covered by L1.

## Out of scope

- Multi-select reveal (right-click ignores selection — acts on the photo under the cursor).
- "Open With…" submenu, "Show Package Contents", or other Finder-style menu items.
- Keyboard shortcut binding.
- Right-click on grid views other than the thumbnail strip and preview (no other photo-rendering surfaces exist today; if added later, they should reuse `FinderReveal.reveal`).

## File touch list (preview)

- `apps/mac-client/SuperPickyApp/FinderReveal.swift` — new file (also register in `SuperPicky.xcodeproj/project.pbxproj` per CLAUDE.md).
- `apps/mac-client/SuperPickyApp/ThumbnailStripView.swift` — add `@Environment(CullingConfig.self)` + `.contextMenu`.
- `apps/mac-client/SuperPickyApp/PreviewView.swift` — add `.contextMenu`.
- `apps/mac-client/SuperPickyUITests/A11y.swift` — add `revealInFinderMenuItem` identifier.
- `apps/mac-client/SuperPickyUITests/CullingWorkflowUITests.swift` — add two XCUITest cases.
- `apps/mac-client/SuperPickyTests/FinderRevealTests.swift` — new L1 test file (also register in pbxproj).

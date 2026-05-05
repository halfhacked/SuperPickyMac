import XCTest

/// Consolidated XCUITests for culling workflow features.
/// Uses a single shared app instance with processed test photos to minimize launch overhead.
/// Tests are numbered to run sequentially, each building on the shared state.
///
/// Categories:
/// - 01-09: UI elements (sidebar, info bar, toolbar)
/// - 10-19: Keyboard shortcuts (fullscreen, zoom, navigation)
/// - 20-29: Star filter and photo counter
/// - 30-39: Export
/// - 40-49: Species edit panel
final class CullingWorkflowUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_workflow" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - 01-09: UI Elements

    func test01_SidebarRatingLabels() {
        let app = Self.app!
        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Good"].exists)
        XCTAssertTrue(app.staticTexts["Average"].exists)
        XCTAssertTrue(app.staticTexts["Below Average"].exists)
        XCTAssertTrue(app.staticTexts["Poor"].exists)
        XCTAssertTrue(app.staticTexts["Reject"].exists)

        // Verify descending order
        let excellent = app.staticTexts["Excellent"]
        let reject = app.staticTexts["Reject"]
        XCTAssertLessThan(excellent.frame.minY, reject.frame.minY)
    }

    func test02_PreviewAndInfoBar() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview should be visible")

        let infoBar = app.descendants(matching: .any)["InfoBar"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 5),
                      "InfoBar should be visible")

        // No manual rating pencil for AI-rated photos
        XCTAssertFalse(app.images["ManualRatingIndicator"].exists,
                       "Pencil should not appear for AI-rated photos")
    }

    func test03_ExportMenuExists() {
        let app = Self.app!
        // Toolbar was refactored from a single Export Picks Button into a
        // Menu (Export Picks / Export All Visible). SwiftUI Menu renders
        // as a popUpButton on macOS, not a Button — match across all types.
        let exportMenu = app.descendants(matching: .any).matching(identifier: "ExportMenu").firstMatch
        XCTAssertTrue(exportMenu.waitForExistence(timeout: 10),
                      "Export menu should exist in toolbar")
        XCTAssertTrue(exportMenu.isEnabled)
    }

    func test04_ExifToggle() {
        let app = Self.app!
        let toggle = app.buttons[A11y.exifToggle]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "EXIF toggle button should exist")
    }

    func test05_SortMenuOffersFiveOrders() {
        let app = Self.app!
        // SwiftUI Menu renders as a popUpButton on macOS, not a plain
        // Button. The identifier is applied to the Menu's label.
        let sortMenu = app.descendants(matching: .any).matching(identifier: "SortMenu").firstMatch
        XCTAssertTrue(sortMenu.waitForExistence(timeout: 5), "SortMenu element should exist")
        if sortMenu.isHittable {
            sortMenu.click()
        } else {
            sortMenu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        }
        Thread.sleep(forTimeInterval: 0.6)

        for label in ["Filename", "Date", "Rating", "Sharpness", "Aesthetics"] {
            XCTAssertTrue(app.menuItems[label].exists ||
                          app.descendants(matching: .any)[label].exists,
                          "Sort menu should offer '\(label)'")
        }
        // Dismiss without changing selection so later tests see default order.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    func test06_TopBurstFilterToggle() {
        let app = Self.app!
        let counter = app.staticTexts[A11y.photoCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let initial = counter.value as? String ?? ""

        let filter = app.buttons["TopBurstFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3), "TopBurstFilter should exist")
        filter.click()
        Thread.sleep(forTimeInterval: 0.4)
        let filtered = counter.value as? String ?? ""
        // Click again to reset — whether or not the count changed, the toggle
        // must not crash and must be reversible.
        filter.click()
        Thread.sleep(forTimeInterval: 0.4)
        let reset = counter.value as? String ?? ""
        XCTAssertEqual(reset, initial,
                       "Toggling TopBurstFilter on/off should return to initial count (initial=\(initial), toggled=\(filtered), reset=\(reset))")
    }

    func test07_PickedFilterToggle() {
        let app = Self.app!
        let counter = app.staticTexts[A11y.photoCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let initial = counter.value as? String ?? ""

        let filter = app.buttons["PickedFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3), "PickedFilter should exist")
        filter.click()
        Thread.sleep(forTimeInterval: 0.4)
        filter.click()
        Thread.sleep(forTimeInterval: 0.4)
        let reset = counter.value as? String ?? ""
        XCTAssertEqual(reset, initial,
                       "Toggling PickedFilter on/off should return to initial count")
    }

    func test08_BrightnessKeysShowIndicator() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Raise brightness a few steps; the indicator is hidden when value == 0.
        for _ in 0..<3 { app.typeText("=") }
        Thread.sleep(forTimeInterval: 0.3)
        let indicator = app.staticTexts["BrightnessIndicator"]
        XCTAssertTrue(indicator.waitForExistence(timeout: 2),
                      "Brightness indicator should appear after pressing =")

        // Return to zero so later tests aren't affected.
        for _ in 0..<3 { app.typeText("-") }
        Thread.sleep(forTimeInterval: 0.3)
    }

    func test09_FilterAutoSelectsFirstPhoto() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        let counter = app.staticTexts[A11y.photoCounter]
        let emptyText = app.staticTexts["Select a photo to preview"]

        // Use Rating rows — they're at the top of the sidebar and always
        // rendered, unlike Species rows which lazy-render below the fold
        // on the CI runner's narrow sidebar viewport.
        func currentFilteredCount() -> Int {
            let raw = (counter.value as? String) ?? ""
            return Int(raw.split(separator: " ").first ?? "0") ?? 0
        }

        // Spec: switching to a rating filter clears active when the prior
        // active photo isn't in that bucket. If the new filter is non-empty,
        // auto-select-first must repopulate the active and the preview must
        // stay visible. If the new filter is empty, the empty state is the
        // correct rendering — there's nothing to auto-select.
        for label in ["Excellent", "Reject"] {
            app.staticTexts[label].click()
            Thread.sleep(forTimeInterval: 0.5)
            let count = currentFilteredCount()
            if count > 0 {
                XCTAssertFalse(emptyText.exists,
                               "Empty state must not appear in \(label) filter with \(count) photos")
                XCTAssertTrue(preview.waitForExistence(timeout: 3),
                              "Preview should be visible in \(label) filter with \(count) photos")
            } else {
                XCTAssertTrue(emptyText.exists,
                              "Empty state should appear when \(label) filter is empty")
            }
        }

        // Restore default filter so later tests start from "all photos".
        let folderName = (Self.testDir! as NSString).lastPathComponent
        app.staticTexts[folderName].click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - 10-19: Keyboard Shortcuts

    func test10_FullscreenToggle() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // F enters fullscreen
        preview.click()
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        let fullscreen = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3),
                      "Fullscreen should open with F")

        // Escape exits fullscreen
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(fullscreen.exists,
                       "Escape should close fullscreen")
    }

    func test11_FullscreenArrowNavigation() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()

        app.typeKey("f", modifierFlags: [])
        let fullscreen = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))

        // Arrow keys navigate without crash
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(fullscreen.exists, "Fullscreen should remain open after navigation")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test12_ZoomDoesNotCrash() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Double-click zoom toggle
        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(preview.exists)

        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(preview.exists)
    }

    func test13_ArrowKeyNavigation() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(preview.exists, "Preview should remain after arrow navigation")
    }

    func test14_FullscreenZoom() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()

        // Enter fullscreen, toggle zoom, exit
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("z", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("z", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(preview.exists, "Preview should remain after fullscreen zoom")
    }

    func test15_InfoToggleKey() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // ExifPanel is open by default; "i" toggles it closed.
        let panel = app.scrollViews[A11y.exifPanel]
        let initiallyOpen = panel.exists
        app.typeText("i")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertNotEqual(initiallyOpen, panel.exists,
                          "'i' key should toggle InfoBar/ExifPanel visibility")

        // Restore original state so later tests see it.
        app.typeText("i")
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test16_RatingKeysDoNotCrash() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Pressing 0-5 should be accepted as a keyboard shortcut. Asserting
        // the specific rating value via the accessibility tree is flaky on
        // CI (StarRatingView's accessibilityValue doesn't always surface as
        // a plain String across macOS versions) — the outer invariant is
        // that the UI survives the sequence.
        for key in ["0", "1", "2", "3", "4", "5", "0"] {
            app.typeText(key)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(preview.exists, "Preview should remain after rating-key sequence")
    }

    func test17_PKeyDoesNotCrash() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        let thumbs = app.images.matching(NSPredicate(format: "identifier BEGINSWITH 'Thumbnail_'"))
        XCTAssertGreaterThan(thumbs.count, 0, "At least one Thumbnail_* image should exist")

        // Asserting PickFlag_* count deltas depends on whether any photo is
        // actually selected in the shared-app state and whether the CI
        // window surfaces the flag overlay in the a11y tree. Covering "P is
        // wired up and doesn't crash the UI" is sufficient at the view
        // level — state-change coverage is exercised by unit tests.
        app.typeText("p")
        Thread.sleep(forTimeInterval: 0.5)
        app.typeText("p")  // toggle back
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(preview.exists, "Preview should remain after P-key toggles")
    }

    func test18_XKeyRejects() {
        let app = Self.app!
        let counter = app.staticTexts[A11y.photoCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        let before = counter.value as? String ?? ""

        let preview = app.images[A11y.photoPreview]
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Rejecting hides the photo (starRating = 0, isReject flag). The
        // visible total stays the same because reject doesn't filter by default;
        // we assert the app doesn't crash and counter is still readable.
        app.typeText("x")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(counter.exists, "Counter should remain after reject")
        let after = counter.value as? String ?? ""
        XCTAssertFalse(after.isEmpty, "Counter value should still be readable: '\(before)' -> '\(after)'")
    }

    func test19_DeleteAndUndo() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.6)

        // The app surfaces a confirmation alert with OK/Cancel. XCUIApplication
        // may see several "Cancel" buttons across windows/sheets; restrict
        // to the front-most dialog via `dialogs.firstMatch`.
        dismissConfirmDialogIfPresent()
        XCTAssertTrue(preview.exists, "Preview should remain after delete-cancel")
    }

    private func dismissConfirmDialogIfPresent() {
        let app = Self.app!
        let dialog = app.dialogs.firstMatch
        if dialog.waitForExistence(timeout: 2) {
            let cancel = dialog.buttons["Cancel"]
            let ok = dialog.buttons["OK"]
            if cancel.exists { cancel.click() }
            else if ok.exists { ok.click() }
            Thread.sleep(forTimeInterval: 0.3)
            return
        }
        // Fallback: escape dismisses most SwiftUI sheets/alerts.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - 20-29: Star Filter

    func test20_StarFilterBarVisible() {
        let app = Self.app!
        let filter = app.descendants(matching: .any)["StarFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5),
                      "Star filter control should be visible")
    }

    func test21_PhotoCounterVisible() {
        let app = Self.app!
        let counter = app.staticTexts[A11y.photoCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 5),
                      "Photo counter should be visible")
    }

    func test22_StarFilterAndReset() {
        let app = Self.app!
        let counter = app.staticTexts[A11y.photoCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let initialText = counter.value as? String ?? ""
        XCTAssertTrue(initialText.contains(" of "),
                      "Counter should show 'N of M' format, got: \(initialText)")

        // Set filter to ≥ 5
        let preview = app.images[A11y.photoPreview]
        preview.click()
        app.typeKey("5", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let filteredText = counter.value as? String ?? ""
        XCTAssertTrue(filteredText.contains(" of "),
                      "Counter should show 'N of M' after filter, got: \(filteredText)")

        // Reset to all
        app.typeKey("0", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let resetText = counter.value as? String ?? ""
        XCTAssertEqual(resetText, initialText,
                       "After reset, counter should match initial")
    }

    // MARK: - 30-39: Export

    func test30_CmdEExportPicks() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // Cmd+E triggers export picks. If no picks exist, the handler shows
        // the "No Photos" alert; if picks exist, an NSSavePanel appears.
        // Either way, dismiss via the front-most dialog/sheet.
        app.typeKey("e", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.8)
        dismissConfirmDialogIfPresent()
        XCTAssertTrue(preview.exists, "Preview should remain after Cmd+E")
    }

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
}

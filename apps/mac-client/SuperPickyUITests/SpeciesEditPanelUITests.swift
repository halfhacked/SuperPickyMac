import XCTest

/// XCUITests for the species edit panel (EXIF panel toggle + species-
/// assignment flow). Split out from CullingWorkflowUITests so the panel
/// tests get a fresh app launch — test30's Cmd+E export dialog was
/// leaking state into test41 when the two test groups shared one app.
final class SpeciesEditPanelUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_species_edit" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

    // Thumbnail identifiers repeat in the accessibility tree (favorite badge
    // etc.); `.firstMatch` picks the top-level image view the existing
    // screenshot tests target too.
    private func selectThumbnail(filename: String) {
        let thumb = Self.app.images.matching(identifier: A11y.thumbnail(filename)).firstMatch

        // The strip is a LazyHStack — thumbnails outside the visible range
        // aren't in the a11y tree yet. If our target isn't rendered, arrow
        // through the strip (both directions — it may be before or after
        // the current selection) to force lazy instantiation.
        if !thumb.waitForExistence(timeout: 2) {
            arrowStripUntil({ thumb.exists }, pressesPerDirection: 50)
        }
        XCTAssertTrue(thumb.waitForExistence(timeout: 10),
                      "\(filename) thumbnail should exist")

        // Rendered but not hittable = off-screen. Arrow in chunks of 5 to
        // amortise the expensive isHittable query.
        if !thumb.isHittable {
            arrowStripUntil({ thumb.isHittable }, pressesPerDirection: 30, batchSize: 5)
        }
        thumb.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Arrow-key the thumbnail strip in both directions (right, then left)
    /// until `condition` is true or the press budget is exhausted.
    /// `batchSize > 1` skips the condition check between presses — use
    /// when the check is expensive (`isHittable`) but not when it's cheap
    /// (`exists`).
    private func arrowStripUntil(_ condition: () -> Bool,
                                 pressesPerDirection: Int,
                                 batchSize: Int = 1) {
        // Clear keyboard focus from any text field so arrow keys land on
        // the app-level NSEvent monitor. Prefer clicking PhotoPreview;
        // fall back to Escape if it's not yet in the tree (slow-CI race
        // where the auto-selected photo hasn't finished decoding).
        let preview = Self.app.images[A11y.photoPreview]
        if preview.exists {
            preview.click()
        } else {
            Self.app.typeKey(.escape, modifierFlags: [])
        }
        for direction in [XCUIKeyboardKey.rightArrow, .leftArrow] {
            var pressed = 0
            while pressed < pressesPerDirection {
                if condition() { return }
                for _ in 0..<batchSize { Self.app.typeKey(direction, modifierFlags: []) }
                pressed += batchSize
            }
        }
    }

    private func selectEaglePhoto() { selectThumbnail(filename: "DSC09969.jpg") }

    // SearchField sits at the bottom of a scrollable panel and can be pruned
    // from the accessibility tree when scrolled out of view. The root
    // ScrollView's identifier is a stable proxy for "panel is mounted".
    private func panelIsOpen() -> Bool {
        Self.app.scrollViews[A11y.exifPanel].exists
    }

    // On macOS CI (GitHub Actions runner), SwiftUI toolbar buttons surface as a
    // nested Button→Button pair that share the accessibility identifier, so a
    // plain subscript query matches twice. `.firstMatch` picks the outer one.
    private func toolbarButton(_ identifier: String) -> XCUIElement {
        Self.app.buttons.matching(identifier: identifier).firstMatch
    }
    private var exifToggleButton: XCUIElement { toolbarButton(A11y.exifToggle) }

    private func ensurePanelClosed() {
        guard panelIsOpen() else { return }
        exifToggleButton.click()
        _ = poll(timeout: 2) { !panelIsOpen() }
    }

    private func openPanelOnEagle() {
        ensurePanelClosed()
        selectEaglePhoto()
        exifToggleButton.click()
        XCTAssertTrue(Self.app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3),
                      "Panel should open")
        // Species sits below EXIF in the scrollable panel. On small windows
        // (CI) the species section is below the fold; scroll it into view
        // so Remove_/Add_/MakePrimary_ buttons and SearchField are hittable.
        scrollPanelToBottom()
        resetEagleSpeciesToBaleagOnly()
    }

    /// Self-heal for tests that share the eagle photo: each test assumes
    /// the mock fixture's initial state (goleag in Candidates, baleag in
    /// Assigned). Prior tests that modify assignments may leak state if a
    /// `tapButton` coordinate click silently missed on CI, so normalize
    /// the eagle's species here before every test body runs.
    private func resetEagleSpeciesToBaleagOnly() {
        let app = Self.app!
        // Drop goleag if it's still in Assigned from a prior test.
        if app.buttons[A11y.speciesEditRemove("goleag")].exists {
            tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
            _ = app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2)
        }
        // Restore baleag if it was removed.
        if !app.buttons[A11y.speciesEditRemove("baleag")].exists,
           app.buttons[A11y.speciesEditAdd("baleag")].exists {
            tapButton(app.buttons[A11y.speciesEditAdd("baleag")])
            _ = app.buttons[A11y.speciesEditRemove("baleag")].waitForExistence(timeout: 2)
        }
    }

    /// Scrolls the ExifPanel down so the species section becomes visible.
    private func scrollPanelToBottom() {
        let panel = Self.app.scrollViews[A11y.exifPanel]
        guard panel.exists else { return }
        panel.scroll(byDeltaX: 0, deltaY: -600)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Click a button reliably on CI. The 12-pt SF-symbol Add/Remove
    /// buttons in the candidates list race between `isHittable` returning
    /// true and the click being dispatched — the click then fails with
    /// "Not hittable". Always using a coordinate click at the reported
    /// centre bypasses the a11y hit test entirely.
    private func tapButton(_ element: XCUIElement) {
        guard element.exists else { return }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    /// Grant keyboard focus to the species search TextField. CI's smaller
    /// window occasionally leaves `field.click()` non-focus-granting, so
    /// approach with a coordinate click first and fall back to a hover +
    /// click pair. Callers verify focus by typing a sentinel character and
    /// reading back `field.value`; if the sentinel didn't land the field
    /// didn't receive focus.
    @discardableResult
    private func focusSearchField() -> XCUIElement {
        let field = Self.app.textFields[A11y.speciesEditPanelSearchField]
        _ = field.waitForExistence(timeout: 3)
        let center = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.click()
        Thread.sleep(forTimeInterval: 0.3)
        field.hover()
        Thread.sleep(forTimeInterval: 0.15)
        center.click()
        Thread.sleep(forTimeInterval: 0.3)
        return field
    }

    /// Returns true if the field currently carries the expected value.
    /// We use this as a focus-granted proxy on macOS where `hasKeyboardFocus`
    /// isn't available on XCUIElement.
    private func fieldValueContains(_ field: XCUIElement, _ needle: String) -> Bool {
        let value = field.value as? String ?? ""
        return value.contains(needle)
    }

    private func clearSearchField() {
        Self.app.typeKey("a", modifierFlags: .command)
        Self.app.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func poll(timeout: TimeInterval, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    private func waitForSidecar(at path: String,
                                containing needle: String,
                                timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) {
            (try? String(contentsOfFile: path))?.contains(needle) ?? false
        }
    }

    private func waitForSidecar(at path: String,
                                satisfying predicate: @escaping (String) -> Bool,
                                timeout: TimeInterval) -> Bool {
        poll(timeout: timeout) {
            guard let contents = try? String(contentsOfFile: path) else { return false }
            return predicate(contents)
        }
    }

    // MARK: - Tests

    func test41_ToggleOpensPanelWithAssignedSpecies() {
        openPanelOnEagle()
        XCTAssertTrue(Self.app.buttons[A11y.speciesEditRemove("baleag")].waitForExistence(timeout: 2))
        ensurePanelClosed()
    }

    func test43_CandidatesListShowsNonAssignedTop5() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("osprey")].exists)
        ensurePanelClosed()
    }

    func test44_AddCandidateMovesToAssigned() {
        let app = Self.app!
        openPanelOnEagle()

        let add = app.buttons[A11y.speciesEditAdd("goleag")]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        tapButton(add)

        let remove = app.buttons[A11y.speciesEditRemove("goleag")]
        XCTAssertTrue(remove.waitForExistence(timeout: 2),
                      "After Add_goleag click, goleag should move to Assigned (Remove_goleag present)")
        XCTAssertFalse(app.buttons[A11y.speciesEditAdd("goleag")].exists)

        tapButton(remove)
        // Verify we actually returned to the initial state so test45 starts clean.
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                      "After Remove_goleag click, goleag should be back in Candidates (Add_goleag present)")
        ensurePanelClosed()
    }

    func test45_RemoveSecondarySpecies() {
        let app = Self.app!
        openPanelOnEagle()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        let remove = app.buttons[A11y.speciesEditRemove("goleag")]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        tapButton(remove)

        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons[A11y.speciesEditRemove("goleag")].exists)
        ensurePanelClosed()
    }

    func test46_SearchFieldAcceptsInput() {
        let app = Self.app!
        openPanelOnEagle()

        let field = focusSearchField()
        app.typeText("robin")
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(fieldValueContains(field, "robin"),
                      "SearchField should contain 'robin' after typing " +
                      "(value=\(String(describing: field.value)))")

        clearSearchField()
        ensurePanelClosed()
    }

    func test47_UnmatchedSearchReturnIsIgnored() {
        let app = Self.app!
        openPanelOnEagle()

        let field = focusSearchField()
        let garbage = "MyCustomSpeciesXYZ"
        app.typeText(garbage)
        // Verify the text landed before pressing Return; if it didn't, the
        // Return-doesn't-add invariant isn't testable in this run.
        guard fieldValueContains(field, garbage) else {
            XCTFail("SearchField did not receive input; cannot verify Return behaviour")
            ensurePanelClosed()
            return
        }
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(app.buttons[A11y.speciesEditRemove(garbage)].exists,
                       "Unmatched Return must not add a custom species")
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("baleag")].exists)

        clearSearchField()
        ensurePanelClosed()
    }

    func test48_EmptyAssignedStateShown() {
        let app = Self.app!
        ensurePanelClosed()
        // DSC09951 is a bird-but-unidentified photo in the mock fixture.
        selectThumbnail(filename: "DSC09951.jpg")
        exifToggleButton.click()
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        scrollPanelToBottom()
        XCTAssertTrue(app.staticTexts[A11y.speciesEditPanelEmptyAssigned].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons[A11y.speciesEditRemove("baleag")].exists)
        ensurePanelClosed()
    }

    func test49_PhotoChangeClearsSearch() {
        let app = Self.app!
        // Reset any lingering filter so the thumbnail strip shows every photo.
        app.typeKey("0", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.3)
        openPanelOnEagle()

        let field = focusSearchField()
        app.typeText("robin")
        Thread.sleep(forTimeInterval: 0.3)
        guard fieldValueContains(field, "robin") else {
            XCTFail("SearchField did not receive input; cannot verify clear-on-photo-change")
            ensurePanelClosed()
            return
        }

        // Select a different photo. Try in preference order so this test
        // survives any prior reject/delete state drift from shared-app tests.
        ensurePanelClosed()
        let candidates = ["DSC09969.jpg", "DSC09970.jpg", "DSC09971.jpg", "DSC09972.jpg"]
        var switched = false
        for name in candidates {
            let thumb = app.images.matching(identifier: A11y.thumbnail(name)).firstMatch
            if thumb.exists {
                selectThumbnail(filename: name)
                switched = true
                break
            }
        }
        guard switched else {
            XCTFail("No alternative thumbnail (\(candidates.joined(separator: ", "))) found to switch to")
            return
        }

        exifToggleButton.click()
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        scrollPanelToBottom()

        let newField = app.textFields[A11y.speciesEditPanelSearchField]
        _ = newField.waitForExistence(timeout: 2)
        XCTAssertFalse(fieldValueContains(newField, "robin"),
                       "Search field should clear on photo change " +
                       "(value=\(String(describing: newField.value)))")

        ensurePanelClosed()
    }

    func test50_RemovePrimaryPromotesNext() {
        let app = Self.app!
        openPanelOnEagle()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons[A11y.speciesEditMakePrimary("goleag")].exists)
        XCTAssertFalse(app.buttons[A11y.speciesEditMakePrimary("baleag")].exists)

        tapButton(app.buttons[A11y.speciesEditRemove("baleag")])
        // Wait for the primary to demote out of Assigned.
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("baleag")].waitForExistence(timeout: 2),
                      "Removed primary (baleag) should reappear in Candidates")
        XCTAssertFalse(app.buttons[A11y.speciesEditRemove("baleag")].exists)
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].exists)
        XCTAssertFalse(app.buttons[A11y.speciesEditMakePrimary("goleag")].exists,
                       "Golden should now be primary (no MakePrimary button)")

        // Restore state for later tests.
        tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
        _ = app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2)
        tapButton(app.buttons[A11y.speciesEditAdd("baleag")])
        _ = app.buttons[A11y.speciesEditRemove("baleag")].waitForExistence(timeout: 2)
        ensurePanelClosed()
    }

    func test51_MakePrimaryReordersAssigned() {
        let app = Self.app!
        openPanelOnEagle()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons[A11y.speciesEditMakePrimary("goleag")].exists)
        XCTAssertFalse(app.buttons[A11y.speciesEditMakePrimary("baleag")].exists)

        tapButton(app.buttons[A11y.speciesEditMakePrimary("goleag")])

        XCTAssertTrue(app.buttons[A11y.speciesEditMakePrimary("baleag")].waitForExistence(timeout: 2),
                      "Bald should now be secondary with a make-primary button")
        XCTAssertFalse(app.buttons[A11y.speciesEditMakePrimary("goleag")].exists)
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].exists)
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("baleag")].exists)

        // Restore: remove goleag so subsequent tests see the default primary.
        tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
        _ = app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2)
        ensurePanelClosed()
    }

    func test52_CandidateRowsShowLevelAndConfidence() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["12%"].exists, "Confidence percentage should render")
        XCTAssertTrue(app.staticTexts["Region"].exists, "thresholdUsed=country → 'Region' label")
        ensurePanelClosed()
    }

    func test53_SpeciesEditWritesToXMPSidecar() {
        let app = Self.app!
        let sidecarPath = (Self.testDir! as NSString).appendingPathComponent("DSC09969.xmp")
        openPanelOnEagle()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].waitForExistence(timeout: 2),
                      "Add click should have moved goleag to Assigned")

        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Golden Eagle", timeout: 3))
        let afterAdd = (try? String(contentsOfFile: sidecarPath)) ?? ""
        XCTAssertTrue(afterAdd.contains("Bald Eagle"))

        tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                      "Remove click should have moved goleag back to Candidates")
        XCTAssertTrue(waitForSidecar(at: sidecarPath,
                                     satisfying: { !$0.contains("Golden Eagle") },
                                     timeout: 3))
        let afterRemove = (try? String(contentsOfFile: sidecarPath)) ?? ""
        XCTAssertTrue(afterRemove.contains("Bald Eagle"))
        ensurePanelClosed()
    }

    // Regression: the EXIF panel's `.task(id:)` was keyed only on photo.id,
    // so species edits (which rewrite the XMP sidecar without changing the
    // id) left the keywords list stale. The panel now hosts both EXIF and
    // species editing, so one toggle is enough.
    func test54_InfoPanelRefreshesKeywordsOnSpeciesEdit() {
        let app = Self.app!
        ensurePanelClosed()
        selectEaglePhoto()

        let sidecarPath = (Self.testDir! as NSString).appendingPathComponent("DSC09969.xmp")
        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Bald Eagle", timeout: 5))

        let baldKeyword = app.staticTexts[A11y.exifKeyword("Bald Eagle")]
        if !baldKeyword.exists {
            exifToggleButton.click()
        }
        XCTAssertTrue(baldKeyword.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[A11y.exifKeyword("Golden Eagle")].exists)

        // Panel already open from the check above; just scroll + normalize.
        if !app.scrollViews[A11y.exifPanel].exists {
            exifToggleButton.click()
        }
        _ = app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3)
        scrollPanelToBottom()
        resetEagleSpeciesToBaleagOnly()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].waitForExistence(timeout: 2),
                      "Add_goleag click should move goleag to Assigned")

        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Golden Eagle", timeout: 3))
        XCTAssertTrue(app.staticTexts[A11y.exifKeyword("Golden Eagle")].waitForExistence(timeout: 5),
                      "EXIF keywords should refresh after species edit")
        XCTAssertTrue(app.staticTexts[A11y.exifKeyword("Bald Eagle")].exists)

        tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                      "Remove click should move goleag back to Candidates")
        XCTAssertTrue(poll(timeout: 4) { !app.staticTexts[A11y.exifKeyword("Golden Eagle")].exists },
                      "Keyword should drop after removal")

        ensurePanelClosed()
        if baldKeyword.exists {
            exifToggleButton.click()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}

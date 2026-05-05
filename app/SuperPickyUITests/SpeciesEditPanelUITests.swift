import XCTest

/// XCUITests for the species edit panel (EXIF panel toggle + species-
/// assignment flow). Split out from CullingWorkflowUITests so the panel
/// tests get a fresh app launch — test30's Cmd+E export dialog was
/// leaking state into test41 when the two test groups shared one app.
final class SpeciesEditPanelUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_species_edit" }

    // Species tests only need 3 photos — the eagle (09969, primary subject),
    // one bird-but-unidentified (09951, for test48's empty-assigned case),
    // and one second eagle (09970, for test49's photo-switch flow). Using a
    // trimmed fixture avoids the ~20s setUp cost of processing 34 photos and
    // eliminates the `arrowStripUntil` detour when selecting thumbnails.
    override class var fixtureFolder: String { "test-photos-species" }

    // Tracks which thumbnail was last selected, so `openPanelOnEagle` can
    // short-circuit the close→reselect→reopen cycle for consecutive eagle
    // tests. Can't be inferred from the panel alone because both DSC09969
    // and DSC09970 render as Bald Eagle in the mock fixture — they'd be
    // indistinguishable via the species buttons.
    private static var currentPhotoFilename: String?

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

    // Fixture only contains 3 photos (09951, 09969, 09970) — they all fit
    // in the thumbnail strip's initial lazy render window, so we can click
    // by identifier directly without the arrow-strip detour the larger
    // shared fixture needs.
    private func selectThumbnail(filename: String) {
        let thumb = Self.app.images.matching(identifier: A11y.thumbnail(filename)).firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 5),
                      "\(filename) thumbnail should exist in the 3-photo species fixture")
        thumb.click()
        // Brief settle so a subsequent `exifToggleButton.click()` doesn't
        // race the still-processing thumbnail selection. Removing this
        // caused a measurable CI regression (waitForExistence(panel) ate
        // most of its 3 s budget instead of returning immediately).
        Thread.sleep(forTimeInterval: 0.3)
        Self.currentPhotoFilename = filename
    }

    private func selectEaglePhoto() { selectThumbnail(filename: "DSC09969.jpg") }

    // SearchField sits at the bottom of a scrollable panel and can be pruned
    // from the accessibility tree when scrolled out of view. The root
    // ScrollView's identifier is a stable proxy for "panel is mounted".
    private func panelIsOpen() -> Bool {
        Self.app.scrollViews[A11y.exifPanel].exists
    }

    /// Fast-path guard for `openPanelOnEagle`: true when a prior eagle test
    /// already left the panel open on DSC09969. Callers that return on
    /// `true` skip the close → reselect → reopen cycle, which is the
    /// dominant per-test cost on CI (two toggle animations per hop).
    private func panelIsOpenOnEagle() -> Bool {
        Self.currentPhotoFilename == "DSC09969.jpg" && panelIsOpen()
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
        _ = poll(timeout: 2) { !self.panelIsOpen() }
    }

    private func openPanelOnEagle() {
        // Fast path: panel already open on the eagle from the previous
        // test in the shared-app suite. Skip the toggle-off / reselect /
        // toggle-on + re-scroll cycle (roughly 2–3 s on the CI runner).
        // The panel's scroll offset persists, so the species section is
        // already visible — only state-normalization is needed.
        if panelIsOpenOnEagle() {
            resetEagleSpeciesToBaleagOnly()
            return
        }
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
        let goleagRemove = app.buttons[A11y.speciesEditRemove("goleag")]
        let baleagRemove = app.buttons[A11y.speciesEditRemove("baleag")]
        let baleagAdd = app.buttons[A11y.speciesEditAdd("baleag")]
        // Fast out when the fixture-default is already in place: baleag in
        // Assigned, goleag not in Assigned. Avoids the redundant
        // `waitForExistence` polls in the branches below for the common
        // case where the prior test left state clean.
        if baleagRemove.exists && !goleagRemove.exists { return }

        // Restore baleag FIRST — if goleag is currently the only Assigned
        // species (e.g., after test50 removed the primary baleag, promoting
        // goleag), removing goleag here would leave zero assigned species
        // and the app's `Remove` action fails silently (the panel refuses
        // to clear the last assigned species on a bird-detected photo).
        // Adding baleag first guarantees there are always ≥2 assigned
        // species when goleag's Remove button is clicked.
        if !baleagRemove.exists, baleagAdd.exists {
            tapButton(baleagAdd)
            XCTAssertTrue(baleagRemove.waitForExistence(timeout: 2),
                          "Reset: baleag should return to Assigned after add")
        }
        if goleagRemove.exists {
            tapButton(goleagRemove)
            XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                          "Reset: goleag should return to Candidates after remove")
        }
    }

    /// Scrolls the ExifPanel down so the species section becomes visible.
    /// A fixed post-scroll settle is simpler and faster on CI than polling
    /// `.isHittable` on candidate elements — each `.isHittable` probe
    /// triggers a snapshot refresh (~0.5 s on the macOS-15 runner) and
    /// calling three of them in a poll loop costs more than a plain 0.3 s
    /// wait. The race being mitigated is: the SwiftUI scroll animation
    /// completes a frame or two after XCUITest returns from `scroll(...)`,
    /// and a coordinate click issued before that frame lands off-screen.
    private func scrollPanelToBottom() {
        let panel = Self.app.scrollViews[A11y.exifPanel]
        guard panel.exists else { return }
        // -600 is the original, proven-on-CI delta. Larger values risk
        // over-scrolling past the scroll-view's content bottom, which
        // XCTest reports as "Unable to find hit point" and aborts the
        // current test.
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
    /// window occasionally leaves a single `field.click()` non-focus-
    /// granting, so approach with a coordinate click first, then a hover
    /// + click pair to cover dropped first-clicks.  Callers verify focus
    /// landed by asserting on the typed value afterwards (`typeAndWaitFor`).
    @discardableResult
    private func focusSearchField() -> XCUIElement {
        let field = Self.app.textFields[A11y.speciesEditPanelSearchField]
        _ = field.waitForExistence(timeout: 3)
        let center = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.click()
        Thread.sleep(forTimeInterval: 0.15)
        field.hover()
        center.click()
        Thread.sleep(forTimeInterval: 0.15)
        return field
    }

    /// Returns true if the field currently carries the expected value.
    /// We use this as a focus-granted proxy on macOS where `hasKeyboardFocus`
    /// isn't available on XCUIElement.
    private func fieldValueContains(_ field: XCUIElement, _ needle: String) -> Bool {
        let value = field.value as? String ?? ""
        return value.contains(needle)
    }

    /// Type `text` into a focused field and poll until the value reflects
    /// it. Replaces the old pattern of `typeText(...)` + fixed `sleep` +
    /// guarded `fieldValueContains` check; now the poll exits on the first
    /// tick where the characters have landed.
    @discardableResult
    private func typeAndWaitFor(_ field: XCUIElement,
                                _ text: String,
                                timeout: TimeInterval = 2) -> Bool {
        Self.app.typeText(text)
        return poll(timeout: timeout) { self.fieldValueContains(field, text) }
    }

    /// Clear the search field's text. Assumes focus is still on the field
    /// (typical path: `focusSearchField()` → `typeAndWaitFor(...)` →
    /// `clearSearchField()` inside the same test). Sends Cmd+A then
    /// Delete which, while the field is focused, stays scoped to the
    /// field's text content — NOT the surrounding app.
    private func clearSearchField() {
        let field = Self.app.textFields[A11y.speciesEditPanelSearchField]
        Self.app.typeKey("a", modifierFlags: .command)
        Self.app.typeKey(.delete, modifierFlags: [])
        // Poll until the value actually empties instead of burning a fixed
        // 0.2 s every clear.
        _ = poll(timeout: 1) { (field.value as? String ?? "").isEmpty }
    }

    private func poll(timeout: TimeInterval, _ check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if check() { return true }
            // Polling tick — the only fixed sleep in the file besides the
            // documented absence-check dwell in test47. 0.15 s balances
            // responsiveness (sub-second exit on the common case) against
            // CPU spin while waiting for the UI to settle.
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
    //
    // Eagle tests (test41–47, test50–54) intentionally do not call
    // `ensurePanelClosed()` at the end of the test body — they leave the
    // panel open on DSC09969 so the next eagle test hits the fast path in
    // `openPanelOnEagle()`. Tests that switch to a different photo
    // (test48 on DSC09951, test49 on DSC09970) DO close the panel at the
    // end so the following eagle test correctly takes the slow path and
    // re-selects DSC09969.

    func test41_ToggleOpensPanelWithAssignedSpecies() {
        openPanelOnEagle()
        XCTAssertTrue(Self.app.buttons[A11y.speciesEditRemove("baleag")].waitForExistence(timeout: 2))
    }

    func test43_CandidatesListShowsNonAssignedTop5() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("osprey")].exists)
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
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                      "After Remove_goleag click, goleag should be back in Candidates (Add_goleag present)")
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
    }

    func test46_SearchFieldAcceptsInput() {
        openPanelOnEagle()

        let field = focusSearchField()
        XCTAssertTrue(typeAndWaitFor(field, "robin"),
                      "SearchField should contain 'robin' after typing " +
                      "(value=\(String(describing: field.value)))")

        clearSearchField()
    }

    func test47_UnmatchedSearchReturnIsIgnored() {
        let app = Self.app!
        openPanelOnEagle()

        let field = focusSearchField()
        let garbage = "MyCustomSpeciesXYZ"
        guard typeAndWaitFor(field, garbage) else {
            XCTFail("SearchField did not receive input; cannot verify Return behaviour")
            clearSearchField()
            return
        }
        app.typeKey(.return, modifierFlags: [])
        // Testing an absence (Return must not add a custom species); there
        // is no positive signal to poll for, so briefly dwell before the
        // negative assertion. 0.3 s is well above the observed SwiftUI
        // action dispatch latency on the CI runner.
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertFalse(app.buttons[A11y.speciesEditRemove(garbage)].exists,
                       "Unmatched Return must not add a custom species")
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("baleag")].exists)

        clearSearchField()
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
        // Leave the panel open; the next test's openPanelOnEagle() takes
        // the slow path (different photo) and closes it before re-opening
        // on the eagle — an explicit close here would just double-pay.
    }

    func test49_PhotoChangeClearsSearch() {
        let app = Self.app!
        // Reset any lingering filter so the thumbnail strip shows every photo.
        app.typeKey("0", modifierFlags: .command)
        openPanelOnEagle()

        let field = focusSearchField()
        guard typeAndWaitFor(field, "robin") else {
            XCTFail("SearchField did not receive input; cannot verify clear-on-photo-change")
            clearSearchField()
            return
        }

        // Switch to DSC09970 (second eagle in the species fixture) — a real
        // photo change that should clear the search.
        ensurePanelClosed()
        selectThumbnail(filename: "DSC09970.jpg")

        exifToggleButton.click()
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        scrollPanelToBottom()

        let newField = app.textFields[A11y.speciesEditPanelSearchField]
        XCTAssertTrue(newField.waitForExistence(timeout: 2))
        XCTAssertFalse(fieldValueContains(newField, "robin"),
                       "Search field should clear on photo change " +
                       "(value=\(String(describing: newField.value)))")
        // Leave the panel open on DSC09970; the next eagle test's
        // openPanelOnEagle() slow path (currentPhotoFilename != DSC09969)
        // closes it before re-opening on the eagle.
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
        // State restoration is handled by `resetEagleSpeciesToBaleagOnly()`
        // at the start of the next test — no need to undo the edits here.
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
        // State restoration is handled by `resetEagleSpeciesToBaleagOnly()`
        // at the start of the next test.
    }

    func test52_CandidateRowsShowLevelAndConfidence() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["12%"].exists, "Confidence percentage should render")
        XCTAssertTrue(app.staticTexts["Region"].exists, "thresholdUsed=country → 'Region' label")
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
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
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

        // Final test in the class — class-level tearDown terminates the
        // app, so no panel close needed here.
    }
}

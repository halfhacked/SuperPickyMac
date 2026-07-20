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
    private func thumbnail(filename: String) -> XCUIElement {
        Self.app.images
            .matching(identifier: A11y.thumbnail(filename))
            .matching(NSPredicate(
                format: "value IN %@",
                [
                    A11y.ThumbnailSelection.active.rawValue,
                    A11y.ThumbnailSelection.selected.rawValue,
                    A11y.ThumbnailSelection.none.rawValue,
                ]
            ))
            .firstMatch
    }

    private func thumbnailIsActive(_ filename: String) -> Bool {
        thumbnail(filename: filename).value as? String
            == A11y.ThumbnailSelection.active.rawValue
    }

    @discardableResult
    private func selectThumbnail(filename: String) -> Bool {
        let thumb = thumbnail(filename: filename)
        XCTAssertTrue(thumb.waitForExistence(timeout: 5),
                      "\(filename) thumbnail should exist in the 3-photo species fixture")
        guard thumb.exists else { return false }

        let active = A11y.ThumbnailSelection.active.rawValue
        if poll(timeout: 0.5, { thumb.value as? String == active }) {
            Self.currentPhotoFilename = filename
            return true
        }

        Self.app.activate()
        for _ in 0..<3 {
            Self.app.typeKey(.leftArrow, modifierFlags: [])
        }
        for position in 0..<3 {
            if poll(timeout: 1, { thumb.value as? String == active }) {
                Self.currentPhotoFilename = filename
                return true
            }
            if position < 2 {
                Self.app.typeKey(.rightArrow, modifierFlags: [])
            }
        }

        XCTFail("\(filename) thumbnail never became active")
        return false
    }

    @discardableResult
    private func selectEaglePhoto() -> Bool {
        selectThumbnail(filename: "DSC09969.jpg")
    }

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
        Self.currentPhotoFilename == "DSC09969.jpg"
            && thumbnailIsActive("DSC09969.jpg")
            && panelIsOpen()
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
        // toggle-on cycle (roughly 2–3 s on the CI runner).
        if panelIsOpenOnEagle() {
            collapseMetadata()
            resetEagleSpeciesToBaleagOnly()
            return
        }
        ensurePanelClosed()
        guard selectEaglePhoto() else { return }
        exifToggleButton.click()
        XCTAssertTrue(Self.app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3),
                      "Panel should open")
        collapseMetadata()
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

    private func setMetadataExpanded(_ expanded: Bool) {
        let toggle = Self.app.buttons.matching(identifier: A11y.exifMetadataToggle).firstMatch
        guard toggle.waitForExistence(timeout: 3) else {
            XCTFail("Metadata toggle should exist")
            return
        }
        let expected = expanded ? "expanded" : "collapsed"
        guard toggle.isHittable else {
            XCTFail("Pinned metadata toggle should be hittable")
            return
        }

        for attempt in 0..<3 {
            if (toggle.value as? String) == expected { return }
            Self.app.activate()
            let center = toggle.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            switch attempt {
            case 0:
                center.press(forDuration: 0.2)
            case 1:
                center.click()
            default:
                toggle.typeKey(.space, modifierFlags: [])
            }
            if poll(timeout: 1, { (toggle.value as? String) == expected }) {
                return
            }
        }
        XCTFail("Metadata should become \(expected)")
    }

    private func collapseMetadata() { setMetadataExpanded(false) }
    private func expandMetadata() { setMetadataExpanded(true) }

    private func collapseCandidates() {
        let toggle = Self.app.buttons
            .matching(identifier: A11y.speciesEditPanelCandidatesToggle)
            .firstMatch
        guard toggle.exists else { return }
        guard (toggle.value as? String) != "collapsed" else { return }
        let panelFrame = Self.app.scrollViews[A11y.exifPanel].frame
        let toggleFrame = toggle.frame
        let toggleCenter = CGPoint(x: toggleFrame.midX, y: toggleFrame.midY)
        guard panelFrame.contains(toggleCenter) else {
            XCTFail("Candidates toggle should be inside the visible panel")
            return
        }
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(poll(timeout: 2) { (toggle.value as? String) == "collapsed" },
                      "Candidates should collapse")
    }

    /// Click a button reliably on CI. The 12–13 pt SF-symbol Add/Remove
    /// buttons in the candidates list race between `isHittable` returning
    /// true and the click being dispatched — `element.click()` then fails
    /// with "Not hittable". A coordinate click at the reported centre
    /// bypasses that a11y hit test, but on the hosted macOS 15.7.x runner a
    /// *raw* coordinate click (mouse-down/up with no preceding pointer move)
    /// is silently dropped by SwiftUI's hover-based hit testing: the button
    /// is found and the click synthesized, yet the action never fires. This
    /// is why the cold first candidate click of the suite (test44's Add)
    /// failed on 184e4b5 while the same code passed on the pre-upgrade
    /// runner. Bring the app frontmost and hover onto the control to prime
    /// the hit test before clicking — the same `activate()` + `hover()`
    /// priming the proven `retryMenuInteraction` path uses.
    private func tapButton(_ element: XCUIElement) {
        guard element.exists else { return }
        Self.app.activate()
        let center = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.hover()
        Thread.sleep(forTimeInterval: 0.1)
        center.click()
    }

    /// Grant keyboard focus to the species search TextField. CI's smaller
    /// window occasionally leaves a single `field.click()` non-focus-
    /// granting, so approach with a coordinate click first, then a hover
    /// + click pair to cover dropped first-clicks.  Callers verify focus
    /// landed by asserting on the typed value afterwards (`typeAndWaitFor`).
    @discardableResult
    private func focusSearchField() -> XCUIElement {
        collapseCandidates()
        let field = Self.app.textFields[A11y.speciesEditPanelSearchField]
        guard field.waitForExistence(timeout: 3) else {
            XCTFail("Search field should exist after collapsible sections are folded")
            return field
        }
        let panelFrame = Self.app.scrollViews[A11y.exifPanel].frame
        let fieldFrame = field.frame
        let fieldCenter = CGPoint(x: fieldFrame.midX, y: fieldFrame.midY)
        guard panelFrame.contains(fieldCenter) else {
            XCTFail("Search field should be inside the visible panel")
            return field
        }
        let center = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
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
        guard selectThumbnail(filename: "DSC09951.jpg") else { return }
        exifToggleButton.click()
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        collapseMetadata()
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
        guard selectThumbnail(filename: "DSC09970.jpg") else { return }

        exifToggleButton.click()
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        collapseMetadata()

        let newField = app.textFields[A11y.speciesEditPanelSearchField]
        XCTAssertTrue(newField.waitForExistence(timeout: 2))
        XCTAssertFalse(fieldValueContains(newField, "robin"),
                       "Search field should clear on photo change " +
                       "(value=\(String(describing: newField.value)))")
        // Leave the panel open on DSC09970; the next eagle test's
        // openPanelOnEagle() slow path (the eagle thumbnail isn't active)
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
        guard selectEaglePhoto() else { return }

        let sidecarPath = (Self.testDir! as NSString).appendingPathComponent("DSC09969.xmp")
        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Bald Eagle", timeout: 5))

        if !app.scrollViews[A11y.exifPanel].exists {
            exifToggleButton.click()
        }
        XCTAssertTrue(app.scrollViews[A11y.exifPanel].waitForExistence(timeout: 3))
        expandMetadata()
        let baldKeyword = app.staticTexts[A11y.exifKeyword("Bald Eagle")]
        XCTAssertTrue(baldKeyword.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts[A11y.exifKeyword("Golden Eagle")].exists)

        // Collapse metadata so the species controls fit without relying on
        // XCUITest scrolling.
        collapseMetadata()
        resetEagleSpeciesToBaleagOnly()

        tapButton(app.buttons[A11y.speciesEditAdd("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditRemove("goleag")].waitForExistence(timeout: 2),
                      "Add_goleag click should move goleag to Assigned")

        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Golden Eagle", timeout: 3))
        expandMetadata()
        XCTAssertTrue(app.staticTexts[A11y.exifKeyword("Golden Eagle")].waitForExistence(timeout: 5),
                      "EXIF keywords should refresh after species edit")
        XCTAssertTrue(app.staticTexts[A11y.exifKeyword("Bald Eagle")].exists)

        collapseMetadata()
        tapButton(app.buttons[A11y.speciesEditRemove("goleag")])
        XCTAssertTrue(app.buttons[A11y.speciesEditAdd("goleag")].waitForExistence(timeout: 2),
                      "Remove click should move goleag back to Candidates")
        expandMetadata()
        XCTAssertTrue(poll(timeout: 4) { !app.staticTexts[A11y.exifKeyword("Golden Eagle")].exists },
                      "Keyword should drop after removal")

        // Final test in the class — class-level tearDown terminates the
        // app, so no panel close needed here.
    }
}

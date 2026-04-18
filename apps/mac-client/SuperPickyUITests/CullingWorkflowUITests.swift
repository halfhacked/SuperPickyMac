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
final class CullingWorkflowUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = NSTemporaryDirectory() + "superpicky_workflow_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: testDir)
        try! FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDir = projectRoot.appendingPathComponent("test-photos").path

        if FileManager.default.fileExists(atPath: sourceDir) {
            let photos = try! FileManager.default.contentsOfDirectory(atPath: sourceDir)
                .filter { $0.hasSuffix(".jpg") }
            for photo in photos {
                try! FileManager.default.copyItem(
                    atPath: (sourceDir as NSString).appendingPathComponent(photo),
                    toPath: (testDir as NSString).appendingPathComponent(photo)
                )
            }
        }

        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()

        // Wait for processing to complete
        _ = app.images.firstMatch.waitForExistence(timeout: 15)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    override class func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(atPath: testDir)
        super.tearDown()
    }

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
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview should be visible")

        let infoBar = app.descendants(matching: .any)["InfoBar"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 5),
                      "InfoBar should be visible")

        // No manual rating pencil for AI-rated photos
        XCTAssertFalse(app.images["ManualRatingIndicator"].exists,
                       "Pencil should not appear for AI-rated photos")
    }

    func test03_ExportPicksButtonExists() {
        let app = Self.app!
        let exportButton = app.buttons["ExportPicksButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10),
                      "Export Picks button should exist in toolbar")
        XCTAssertTrue(exportButton.isEnabled)
    }

    func test04_ExifToggle() {
        let app = Self.app!
        let toggle = app.buttons["ExifToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "EXIF toggle button should exist")
    }

    // MARK: - 10-19: Keyboard Shortcuts

    func test10_FullscreenToggle() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
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
        let preview = app.images["PhotoPreview"]
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
        let preview = app.images["PhotoPreview"]
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
        let preview = app.images["PhotoPreview"]
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
        let preview = app.images["PhotoPreview"]
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

    // MARK: - 20-29: Star Filter

    func test20_StarFilterBarVisible() {
        let app = Self.app!
        let filter = app.descendants(matching: .any)["StarFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5),
                      "Star filter control should be visible")
    }

    func test21_PhotoCounterVisible() {
        let app = Self.app!
        let counter = app.staticTexts["PhotoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5),
                      "Photo counter should be visible")
    }

    func test22_StarFilterAndReset() {
        let app = Self.app!
        let counter = app.staticTexts["PhotoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let initialText = counter.value as? String ?? ""
        XCTAssertTrue(initialText.contains(" of "),
                      "Counter should show 'N of M' format, got: \(initialText)")

        // Set filter to ≥ 5
        let preview = app.images["PhotoPreview"]
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

    // MARK: - 40-49: Species Edit Panel

    // Thumbnail identifiers repeat in the accessibility tree (favorite badge
    // etc.); `.firstMatch` picks the top-level image view the existing
    // screenshot tests target too.
    private func selectThumbnail(filename: String) {
        let thumb = Self.app.images.matching(identifier: "Thumbnail_\(filename)").firstMatch
        XCTAssertTrue(thumb.waitForExistence(timeout: 10),
                      "\(filename) thumbnail should exist")

        // Prior tests may have scrolled the horizontal strip so the target
        // is off-screen. Arrow keys navigate selection *and* auto-scroll;
        // batch into chunks of 5 to amortise the expensive isHittable query.
        if !thumb.isHittable {
            Self.app.images["PhotoPreview"].click()
            for direction in [XCUIKeyboardKey.leftArrow, .rightArrow] {
                for _ in 0..<6 {
                    if thumb.isHittable { break }
                    for _ in 0..<5 { Self.app.typeKey(direction, modifierFlags: []) }
                }
                if thumb.isHittable { break }
            }
        }
        thumb.click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func selectEaglePhoto() { selectThumbnail(filename: "DSC00001.jpg") }

    // The panel's root ScrollView isn't reliably queryable by its accessibility
    // identifier; the search field is unique to the panel and works as a proxy.
    private func panelIsOpen() -> Bool {
        Self.app.textFields["SpeciesEditPanel_SearchField"].exists
    }

    // On macOS CI (GitHub Actions runner), SwiftUI toolbar buttons surface as a
    // nested Button→Button pair that share the accessibility identifier, so a
    // plain subscript query matches twice. `.firstMatch` picks the outer one.
    private func toolbarButton(_ identifier: String) -> XCUIElement {
        Self.app.buttons.matching(identifier: identifier).firstMatch
    }
    private var speciesEditToggleButton: XCUIElement { toolbarButton("SpeciesEditToggle") }
    private var exifToggleButton: XCUIElement { toolbarButton("ExifToggle") }

    private func ensurePanelClosed() {
        guard panelIsOpen() else { return }
        speciesEditToggleButton.click()
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func openPanelOnEagle() {
        ensurePanelClosed()
        selectEaglePhoto()
        speciesEditToggleButton.click()
        XCTAssertTrue(Self.app.textFields["SpeciesEditPanel_SearchField"].waitForExistence(timeout: 3),
                      "Panel should open")
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

    func test40_SpeciesEditToggleExists() {
        XCTAssertTrue(Self.app.buttons["SpeciesEditToggle"].waitForExistence(timeout: 5))
    }

    func test41_ToggleOpensPanelWithAssignedSpecies() {
        openPanelOnEagle()
        XCTAssertTrue(Self.app.buttons["SpeciesEditPanel_Remove_baleag"].waitForExistence(timeout: 2))
        ensurePanelClosed()
    }

    func test42_KeyboardShortcutSToggles() {
        let app = Self.app!
        ensurePanelClosed()
        selectEaglePhoto()

        // PhotoPreview click hands focus back to the NSEvent key monitor.
        app.images["PhotoPreview"].click()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey("s", modifierFlags: [])
        let field = app.textFields["SpeciesEditPanel_SearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 2), "`s` should open panel")

        app.typeKey("s", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(field.exists, "`s` again should close panel")
    }

    func test43_CandidatesListShowsNonAssignedTop5() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_goleag"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_osprey"].exists)
        ensurePanelClosed()
    }

    func test44_AddCandidateMovesToAssigned() {
        let app = Self.app!
        openPanelOnEagle()

        let add = app.buttons["SpeciesEditPanel_Add_goleag"]
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.click()

        let remove = app.buttons["SpeciesEditPanel_Remove_goleag"]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["SpeciesEditPanel_Add_goleag"].exists)

        remove.click()
        Thread.sleep(forTimeInterval: 0.3)
        ensurePanelClosed()
    }

    func test45_RemoveSecondarySpecies() {
        let app = Self.app!
        openPanelOnEagle()

        app.buttons["SpeciesEditPanel_Add_goleag"].click()
        let remove = app.buttons["SpeciesEditPanel_Remove_goleag"]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        remove.click()

        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_goleag"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["SpeciesEditPanel_Remove_goleag"].exists)
        ensurePanelClosed()
    }

    func test46_SearchFieldAcceptsInput() {
        let app = Self.app!
        openPanelOnEagle()

        let field = app.textFields["SpeciesEditPanel_SearchField"]
        field.click()
        field.typeText("robin")
        Thread.sleep(forTimeInterval: 0.3)

        let value = field.value as? String ?? ""
        XCTAssertTrue(value.contains("robin"), "Got: \(value)")

        clearSearchField()
        ensurePanelClosed()
    }

    func test47_UnmatchedSearchReturnIsIgnored() {
        let app = Self.app!
        openPanelOnEagle()

        let field = app.textFields["SpeciesEditPanel_SearchField"]
        field.click()
        let garbage = "MyCustomSpeciesXYZ"
        field.typeText(garbage)
        app.typeKey(.return, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(app.buttons["SpeciesEditPanel_Remove_\(garbage)"].exists,
                       "Unmatched Return must not add a custom species")
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_baleag"].exists)

        clearSearchField()
        ensurePanelClosed()
    }

    func test48_EmptyAssignedStateShown() {
        let app = Self.app!
        ensurePanelClosed()
        // DSC00029 is a bird-but-unidentified photo in the mock fixture.
        selectThumbnail(filename: "DSC00029.jpg")
        speciesEditToggleButton.click()
        XCTAssertTrue(app.textFields["SpeciesEditPanel_SearchField"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["SpeciesEditPanel_EmptyAssigned"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["SpeciesEditPanel_Remove_baleag"].exists)
        ensurePanelClosed()
    }

    func test49_PhotoChangeClearsSearch() {
        let app = Self.app!
        openPanelOnEagle()

        let field = app.textFields["SpeciesEditPanel_SearchField"]
        field.click()
        field.typeText("transient")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue((field.value as? String ?? "").contains("transient"))

        // Click a sibling thumbnail rather than pressing arrow keys — while
        // the search field has focus, the app's NSEvent monitor skips keys.
        let sibling = app.images.matching(identifier: "Thumbnail_DSC00003.jpg").firstMatch
        XCTAssertTrue(sibling.waitForExistence(timeout: 5))
        sibling.click()
        Thread.sleep(forTimeInterval: 0.8)

        let cleared = (field.value as? String ?? "")
        XCTAssertTrue(cleared.isEmpty || cleared == "Search species",
                      "Got: '\(cleared)'")
        ensurePanelClosed()
    }

    func test50_RemovePrimaryPromotesNext() {
        let app = Self.app!
        openPanelOnEagle()

        app.buttons["SpeciesEditPanel_Add_goleag"].click()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_goleag"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["SpeciesEditPanel_MakePrimary_goleag"].exists)
        XCTAssertFalse(app.buttons["SpeciesEditPanel_MakePrimary_baleag"].exists)

        app.buttons["SpeciesEditPanel_Remove_baleag"].click()
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(app.buttons["SpeciesEditPanel_Remove_baleag"].exists)
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_goleag"].exists)
        XCTAssertFalse(app.buttons["SpeciesEditPanel_MakePrimary_goleag"].exists,
                       "Golden should now be primary")
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_baleag"].waitForExistence(timeout: 2))

        // Restore state for later tests.
        app.buttons["SpeciesEditPanel_Remove_goleag"].click()
        Thread.sleep(forTimeInterval: 0.3)
        app.buttons["SpeciesEditPanel_Add_baleag"].click()
        Thread.sleep(forTimeInterval: 0.3)
        ensurePanelClosed()
    }

    func test51_MakePrimaryReordersAssigned() {
        let app = Self.app!
        openPanelOnEagle()

        app.buttons["SpeciesEditPanel_Add_goleag"].click()
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertTrue(app.buttons["SpeciesEditPanel_MakePrimary_goleag"].exists)
        XCTAssertFalse(app.buttons["SpeciesEditPanel_MakePrimary_baleag"].exists)

        app.buttons["SpeciesEditPanel_MakePrimary_goleag"].click()

        XCTAssertTrue(app.buttons["SpeciesEditPanel_MakePrimary_baleag"].waitForExistence(timeout: 2),
                      "Bald should now have a make-primary button as secondary")
        XCTAssertFalse(app.buttons["SpeciesEditPanel_MakePrimary_goleag"].exists)
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_goleag"].exists)
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_baleag"].exists)

        app.buttons["SpeciesEditPanel_Remove_goleag"].click()
        Thread.sleep(forTimeInterval: 0.3)
        ensurePanelClosed()
    }

    func test52_CandidateRowsShowLevelAndConfidence() {
        let app = Self.app!
        openPanelOnEagle()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_goleag"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["12%"].exists, "Confidence percentage should render")
        XCTAssertTrue(app.staticTexts["Region"].exists, "thresholdUsed=country → 'Region' label")
        ensurePanelClosed()
    }

    func test53_SpeciesEditWritesToXMPSidecar() {
        let app = Self.app!
        let sidecarPath = (Self.testDir! as NSString).appendingPathComponent("DSC00001.xmp")
        openPanelOnEagle()

        app.buttons["SpeciesEditPanel_Add_goleag"].click()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_goleag"].waitForExistence(timeout: 2))

        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Golden Eagle", timeout: 3))
        let afterAdd = (try? String(contentsOfFile: sidecarPath)) ?? ""
        XCTAssertTrue(afterAdd.contains("Bald Eagle"))

        app.buttons["SpeciesEditPanel_Remove_goleag"].click()
        XCTAssertTrue(waitForSidecar(at: sidecarPath,
                                     satisfying: { !$0.contains("Golden Eagle") },
                                     timeout: 3))
        let afterRemove = (try? String(contentsOfFile: sidecarPath)) ?? ""
        XCTAssertTrue(afterRemove.contains("Bald Eagle"))
        ensurePanelClosed()
    }

    // Regression: the EXIF panel's `.task(id:)` was keyed only on photo.id,
    // so species edits (which rewrite the XMP sidecar without changing the
    // id) left the keywords list stale.
    func test54_InfoPanelRefreshesKeywordsOnSpeciesEdit() {
        let app = Self.app!
        ensurePanelClosed()
        selectEaglePhoto()

        let sidecarPath = (Self.testDir! as NSString).appendingPathComponent("DSC00001.xmp")
        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Bald Eagle", timeout: 5))

        let baldKeyword = app.staticTexts["ExifKeyword_Bald Eagle"]
        if !baldKeyword.exists {
            exifToggleButton.click()
        }
        XCTAssertTrue(baldKeyword.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["ExifKeyword_Golden Eagle"].exists)

        speciesEditToggleButton.click()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Add_goleag"].waitForExistence(timeout: 3))
        app.buttons["SpeciesEditPanel_Add_goleag"].click()
        XCTAssertTrue(app.buttons["SpeciesEditPanel_Remove_goleag"].waitForExistence(timeout: 2))

        XCTAssertTrue(waitForSidecar(at: sidecarPath, containing: "Golden Eagle", timeout: 3))
        XCTAssertTrue(app.staticTexts["ExifKeyword_Golden Eagle"].waitForExistence(timeout: 5),
                      "EXIF keywords should refresh after species edit")
        XCTAssertTrue(app.staticTexts["ExifKeyword_Bald Eagle"].exists)

        app.buttons["SpeciesEditPanel_Remove_goleag"].click()
        XCTAssertTrue(poll(timeout: 4) { !app.staticTexts["ExifKeyword_Golden Eagle"].exists },
                      "Keyword should drop after removal")

        ensurePanelClosed()
        if baldKeyword.exists {
            exifToggleButton.click()
            Thread.sleep(forTimeInterval: 0.3)
        }
    }
}

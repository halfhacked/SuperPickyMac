import XCTest

/// XCUITest coverage for filmstrip multi-select and batch operations.
///
/// Tests share one app instance via `SuperPickyUITestCase`, so each test
/// must be independent of prior flag / rating state. P, U, and X are
/// idempotent setters, so each test can drive the selection to a known state.
final class BatchSelectionUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_batch" }
    /// Use the small species fixture (3 photos) so the LazyHStack renders
    /// every thumbnail in the initial pass — no `arrowStripUntil` detour.
    override class var fixtureFolder: String { "test-photos-species" }

    private var app: XCUIApplication { Self.app }
    private var testDir: String { Self.testDir }

    // MARK: - Helpers

    /// SwiftUI exposes the thumbnail cell to the a11y tree under multiple
    /// nested elements that all carry the cell's `accessibilityIdentifier`,
    /// so `app.images[id]` raises "multiple matching elements". Use the
    /// query + firstMatch idiom (same as `SpeciesEditPanelUITests`).
    private func thumbnail(_ filename: String) -> XCUIElement {
        app.images.matching(identifier: A11y.thumbnail(filename)).firstMatch
    }

    private func clickThumbnail(_ filename: String,
                                modifiers: XCUIElement.KeyModifierFlags = []) {
        let thumb = thumbnail(filename)
        XCTAssertTrue(thumb.waitForExistence(timeout: 5),
                      "Thumbnail \(filename) never appeared")
        if modifiers.isEmpty {
            thumb.click()
        } else {
            XCUIElement.perform(withKeyModifiers: modifiers) {
                thumb.click()
            }
        }
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func a11ySelection(of filename: String) -> String? {
        thumbnail(filename).value as? String
    }

    private func xmp(for filename: String) throws -> String {
        let path = (testDir as NSString)
            .appendingPathComponent((filename as NSString)
                .deletingPathExtension + ".xmp")
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func pickStatus(_ filename: String) -> Int? {
        let body = (try? xmp(for: filename)) ?? ""
        if body.contains("xmp:PickStatus=\"-1\"") { return -1 }
        if body.contains("xmp:PickStatus=\"0\"") { return 0 }
        if body.contains("xmp:PickStatus=\"1\"") { return 1 }
        return nil
    }

    private func fixtureFilenames() -> [String] {
        let url = SuperPickyUITestCase.fixturesRoot
            .appendingPathComponent(Self.fixtureFolder)
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .filter { $0.hasSuffix(".jpg") }
            .sorted() ?? []
    }

    private func selectAllThree(_ names: [String]) {
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
    }

    private func forceAllPicked(_ names: [String]) {
        selectAllThree(names)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Tests

    func testShiftClickRangeSelectsContiguousThumbnails() {
        let names = fixtureFilenames()
        guard names.count >= 3 else {
            XCTFail("Need at least 3 fixtures, got \(names.count)")
            return
        }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)

        XCTAssertEqual(a11ySelection(of: names[0]), "selected")
        XCTAssertEqual(a11ySelection(of: names[1]), "selected")
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
        // SwiftUI's Text(verbatim:) + .accessibilityIdentifier() doesn't
        // surface the rendered text as XCUIElement.label, so we just verify
        // the counter element appears (proves isMulti is true).
        XCTAssertTrue(app.staticTexts[A11y.selectionCounter].waitForExistence(timeout: 2),
                      "Selection counter should appear when 3 photos are selected")
    }

    func testCmdClickTogglesIndividualSelection() {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .command)
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
        XCTAssertEqual(a11ySelection(of: names[0]), "selected")

        clickThumbnail(names[2], modifiers: .command)
        XCTAssertEqual(a11ySelection(of: names[2]), "none")
    }

    func testCmdAUsesSelectAll() {
        let names = fixtureFilenames()
        guard let first = names.first else { return }
        clickThumbnail(first)
        app.typeKey("a", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(app.staticTexts[A11y.selectionCounter].waitForExistence(timeout: 2),
                      "Cmd+A should make the multi-select counter appear")
        // Verify each thumbnail is in the selection (active for first, the
        // pre-Cmd+A active; selected for the rest). The accessibility value
        // distinguishes selected vs. none, so this proves all 3 are in the set.
        for n in names.prefix(3) {
            let v = a11ySelection(of: n)
            XCTAssertTrue(v == "selected" || v == "active",
                          "Cmd+A should leave \(n) in the selection (got \(v ?? "nil"))")
        }
    }

    func testEscCollapsesMultiSelect() {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertFalse(app.staticTexts[A11y.selectionCounter].exists)
        XCTAssertEqual(a11ySelection(of: names[2]), "active")
    }

    func testBatchPickSetsAllSelectedPhotos() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        selectAllThree(names)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        for name in names.prefix(3) {
            XCTAssertEqual(pickStatus(name), 1, "XMP for \(name) should be picked")
        }
    }

    func testBatchUnflagClearsPickedState() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        forceAllPicked(names)
        selectAllThree(names)
        app.typeKey("u", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        for name in names.prefix(3) {
            XCTAssertEqual(pickStatus(name), 0, "XMP for \(name) should be unflagged")
        }
    }

    func testBatchUnflagClearsRejectedState() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        selectAllThree(names)
        app.typeKey("x", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("u", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        for name in names.prefix(3) {
            XCTAssertEqual(pickStatus(name), 0, "XMP for \(name) should be unflagged")
        }
    }

    func testBatchRateSetsStarsOnAllSelected() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        selectAllThree(names)
        app.typeKey("3", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        for n in names.prefix(3) {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("xmp:Rating=\"3\""),
                          "XMP for \(n) does not show 3-star rating")
        }
    }

    func testOneStepUndoForBatchEdit() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        // Start unflagged, pick the batch, then verify one undo restores 0.
        selectAllThree(names)
        app.typeKey("u", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        for name in names.prefix(3) {
            XCTAssertEqual(pickStatus(name), 0,
                           "XMP for \(name) should restore unflagged state after undo")
        }
    }
}

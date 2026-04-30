import XCTest

/// XCUITest coverage for filmstrip multi-select and batch operations.
/// Per project rules:
///   - All `waitForExistence` results are XCTAssert'd (silent-timeout rule).
///   - Off-screen thumbnails are reached via `arrowStripUntil`
///     (LazyHStack lazy-instantiation rule).
///   - On-disk side effects (XMP) are read after each batch op
///     (verify-disk-side-effects rule).
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

    private func selectionCounterText() -> String? {
        let counter = app.staticTexts[A11y.selectionCounter]
        guard counter.waitForExistence(timeout: 2) else { return nil }
        return counter.label
    }

    private func xmp(for filename: String) throws -> String {
        let path = (testDir as NSString)
            .appendingPathComponent((filename as NSString)
                .deletingPathExtension + ".xmp")
        return try String(contentsOfFile: path, encoding: .utf8)
    }

    private func fixtureFilenames() -> [String] {
        let url = SuperPickyUITestCase.fixturesRoot
            .appendingPathComponent(Self.fixtureFolder)
        return (try? FileManager.default.contentsOfDirectory(atPath: url.path))?
            .filter { $0.hasSuffix(".jpg") }
            .sorted() ?? []
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
        XCTAssertTrue(selectionCounterText()?.contains("3") ?? false,
                      "Expected counter to mention 3 selected photos")
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
        let counter = app.staticTexts[A11y.selectionCounter]
        XCTAssertTrue(counter.waitForExistence(timeout: 2))
        XCTAssertTrue(counter.label.contains("\(names.count)"),
                      "Counter should equal the fixture's photo count: \(counter.label)")
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

    func testBatchPickViaKeyboard() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        for n in names.prefix(3) {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("xmp:PickStatus=\"1\""),
                          "XMP for \(n) does not reflect picked state: \(body.prefix(400))")
        }
    }

    func testBatchUnpickViaKeyboard() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        for n in names.prefix(3) {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("xmp:PickStatus=\"0\""),
                          "XMP for \(n) should be unpicked")
        }
    }

    func testBatchRateSetsStarsOnAllSelected() throws {
        let names = fixtureFilenames()
        guard names.count >= 3 else { return }
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
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
        clickThumbnail(names[0])
        clickThumbnail(names[2], modifiers: .shift)
        app.typeKey("p", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey("z", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 0.5)
        for n in names.prefix(3) {
            let body = try xmp(for: n)
            XCTAssertTrue(body.contains("xmp:PickStatus=\"0\""),
                          "XMP for \(n) should be unpicked after undo")
        }
    }
}

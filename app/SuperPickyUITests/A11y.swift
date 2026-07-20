import Foundation

/// Accessibility identifiers used from UI tests. Mirrors the string
/// literals set via `.accessibilityIdentifier(...)` in the app; keeping
/// them here means the test side is typed and a rename only updates one
/// call site. When adding a new identifier in the app, add it here too.
enum A11y {
    static let photoPreview = "PhotoPreview"
    static let exifPanel = "ExifPanel"
    static let exifToggle = "ExifToggle"
    static let photoCounter = "PhotoCounter"
    static let speciesEditPanelSearchField = "SpeciesEditPanel_SearchField"
    static let speciesEditPanelEmptyAssigned = "SpeciesEditPanel_EmptyAssigned"
    static let selectionCounter = "SelectionCounter"
    static let revealInFinderMenuItem = "RevealInFinder"

    /// Accessibility values used by ThumbnailCell — match
    /// `ThumbnailCell.a11ySelectionValue`.
    enum ThumbnailSelection: String {
        case active
        case selected
        case none
    }

    static func thumbnail(_ filename: String) -> String {
        "Thumbnail_\(filename)"
    }
    static func speciesEditAdd(_ ebirdCode: String) -> String {
        "SpeciesEditPanel_Add_\(ebirdCode)"
    }
    static func speciesEditRemove(_ ebirdCode: String) -> String {
        "SpeciesEditPanel_Remove_\(ebirdCode)"
    }
    static func speciesEditMakePrimary(_ ebirdCode: String) -> String {
        "SpeciesEditPanel_MakePrimary_\(ebirdCode)"
    }
    static func exifKeyword(_ label: String) -> String {
        "ExifKeyword_\(label)"
    }
}

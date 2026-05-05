import AppKit
import Foundation

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

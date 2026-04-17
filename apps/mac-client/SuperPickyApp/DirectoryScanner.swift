import Foundation

struct DirectoryScanner: Sendable {
    private static let supportedExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq",
        "hif", "heif", "heic",
        "jpg", "jpeg"
    ]

    func scan(folder: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var results: [URL] = []
        for case let url as URL in enumerator {
            if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        // Sort by (parent path, filename) so bursts within a single
        // subfolder stay contiguous under the timestamp resort.
        return results.sorted {
            let lp = $0.deletingLastPathComponent().path
            let rp = $1.deletingLastPathComponent().path
            if lp != rp { return lp < rp }
            return $0.lastPathComponent < $1.lastPathComponent
        }
    }
}

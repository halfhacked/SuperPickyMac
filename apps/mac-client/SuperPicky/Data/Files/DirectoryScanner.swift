import Foundation

struct DirectoryScanner: Sendable {
    private static let supportedExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq",
        "hif", "heif", "heic",
        "jpg", "jpeg"
    ]

    func scan(folder: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents.filter { url in
            Self.supportedExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

import Foundation

struct FileOrganizer: Sendable {
    func folderName(for starRating: Int) -> String {
        switch starRating {
        case 0: "0star_reject"
        case 1: "1star_average"
        case 2: "2star_good"
        case 3: "3star_excellent"
        default: "unrated"
        }
    }

    func organize(file: URL, starRating: Int, inFolder folder: URL) throws {
        let destFolder = folder.appendingPathComponent(folderName(for: starRating))
        try FileManager.default.createDirectory(at: destFolder, withIntermediateDirectories: true)
        let destFile = destFolder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: destFile)
    }
}

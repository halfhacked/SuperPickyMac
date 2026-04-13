import Foundation

/// Metadata extracted from an image file's EXIF, TIFF, and IPTC dictionaries.
struct EXIFData: Sendable {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?       // mm
    var aperture: Double?          // f-number
    var shutterSpeed: String?      // formatted: "1/500" or "2.5s"
    var iso: Int?
    var dateTimeOriginal: String?  // raw EXIF string "2024:03:15 14:30:22"
    var imageWidth: Int?
    var imageHeight: Int?
    var exposureBias: Double?
    var meteringMode: String?
    var whiteBalance: String?
    var keywords: [String] = []    // IPTC keywords, empty if none
}

/// Reads EXIF metadata from image files using ImageIO.
enum EXIFReader {
    /// Returns nil if the file does not exist or cannot be read as an image.
    static func read(from filePath: String) -> EXIFData? {
        // Stub — returns nil for now
        return nil
    }
}

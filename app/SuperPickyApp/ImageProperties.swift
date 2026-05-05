import Foundation
import CoreGraphics
import ImageIO

/// One-shot `CGImageSourceCopyPropertiesAtIndex` wrapper. Callers that need
/// several slices of EXIF (EXIFReader + FocusPointDetector + timestamp reader)
/// share this dict instead of each reopening the file.
enum ImageProperties {
    static func load(filePath: String) -> [String: Any]? {
        let url = URL(fileURLWithPath: filePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }
        return props
    }
}

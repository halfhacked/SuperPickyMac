import Foundation
import CoreGraphics
import ImageIO

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

    // GPS
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?          // meters

    // IPTC location
    var city: String?
    var state: String?
    var country: String?

    /// True when no meaningful EXIF metadata is present.
    /// Excludes imageWidth/imageHeight since those are always available from the image container.
    var isEmpty: Bool {
        cameraMake == nil && cameraModel == nil && lensModel == nil &&
        focalLength == nil && aperture == nil && shutterSpeed == nil &&
        iso == nil && dateTimeOriginal == nil && exposureBias == nil &&
        meteringMode == nil && whiteBalance == nil && keywords.isEmpty &&
        latitude == nil && longitude == nil && altitude == nil &&
        city == nil && state == nil && country == nil
    }
}

/// Reads EXIF metadata from image files using ImageIO.
enum EXIFReader {
    /// Returns nil if the file does not exist or cannot be read as an image.
    static func read(from filePath: String) -> EXIFData? {
        guard let properties = ImageProperties.load(filePath: filePath) else {
            return nil
        }
        return parse(properties: properties, imagePath: filePath)
    }

    /// Parse EXIF from a pre-loaded properties dict. Lets callers share one
    /// `CGImageSourceCopyPropertiesAtIndex` call across multiple consumers
    /// (EXIFReader + FocusPointDetector) to avoid re-reading the file.
    static func parse(properties: [String: Any], imagePath: String) -> EXIFData {
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]

        var data = EXIFData()

        // TIFF
        data.cameraMake = tiff?[kCGImagePropertyTIFFMake as String] as? String
        data.cameraModel = tiff?[kCGImagePropertyTIFFModel as String] as? String

        // Lens: prefer ExifAux, fallback to Exif
        data.lensModel = (exifAux?[kCGImagePropertyExifAuxLensModel as String] as? String)
            ?? (exif?[kCGImagePropertyExifLensModel as String] as? String)

        // Exif numerics
        data.focalLength = doubleValue(exif, key: kCGImagePropertyExifFocalLength as String)
        data.aperture = doubleValue(exif, key: kCGImagePropertyExifFNumber as String)
        data.exposureBias = doubleValue(exif, key: kCGImagePropertyExifExposureBiasValue as String)

        // ISO
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any],
           let first = isoArray.first {
            data.iso = intValue(first)
        }

        // Shutter speed (ExposureTime)
        if let exposure = doubleValue(exif, key: kCGImagePropertyExifExposureTime as String) {
            data.shutterSpeed = formatShutterSpeed(exposure)
        }

        // Date
        data.dateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String

        // Metering mode
        if let mode = exif?[kCGImagePropertyExifMeteringMode as String] {
            data.meteringMode = describeMeteringMode(intValue(mode))
        }

        // White balance
        if let wb = exif?[kCGImagePropertyExifWhiteBalance as String] {
            data.whiteBalance = intValue(wb) == 0 ? "Auto" : "Manual"
        }

        // Dimensions (top-level)
        data.imageWidth = properties[kCGImagePropertyPixelWidth as String] as? Int
        data.imageHeight = properties[kCGImagePropertyPixelHeight as String] as? Int

        // Keywords: IPTC first, then merge in dc:subject from the sibling
        // `.xmp` sidecar if one exists. The pipeline writes keywords to the
        // sidecar only (RAWs aren't rewritten), so the sidecar is the source
        // of truth for anything we generated (species, flight).
        var keywords: [String] = []
        var seen: Set<String> = []
        if let kw = iptc?[kCGImagePropertyIPTCKeywords as String] as? [String] {
            for k in kw where seen.insert(k).inserted { keywords.append(k) }
        }
        for k in readXMPKeywords(imagePath: imagePath) where seen.insert(k).inserted {
            keywords.append(k)
        }
        data.keywords = keywords

        // GPS
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        if let lat = doubleValue(gps, key: kCGImagePropertyGPSLatitude as String) {
            let ref = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String
            data.latitude = ref == "S" ? -lat : lat
        }
        if let lon = doubleValue(gps, key: kCGImagePropertyGPSLongitude as String) {
            let ref = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String
            data.longitude = ref == "W" ? -lon : lon
        }
        data.altitude = doubleValue(gps, key: kCGImagePropertyGPSAltitude as String)

        // IPTC location
        data.city = iptc?[kCGImagePropertyIPTCCity as String] as? String
        data.state = iptc?[kCGImagePropertyIPTCProvinceState as String] as? String
        data.country = iptc?[kCGImagePropertyIPTCCountryPrimaryLocationName as String] as? String

        return data
    }

    // MARK: - Private helpers

    private static func doubleValue(_ dict: [String: Any]?, key: String) -> Double? {
        guard let val = dict?[key] else { return nil }
        if let d = val as? Double { return d }
        if let n = val as? NSNumber { return n.doubleValue }
        if let s = val as? String { return Double(s) }
        return nil
    }

    private static func intValue(_ val: Any) -> Int? {
        if let i = val as? Int { return i }
        if let n = val as? NSNumber { return n.intValue }
        return nil
    }

    private static func formatShutterSpeed(_ exposure: Double) -> String {
        if exposure >= 1.0 {
            // Format as "Ns" — remove trailing zero for whole numbers
            if exposure == exposure.rounded() {
                return "\(Int(exposure))s"
            }
            return "\(exposure)s"
        }
        let denominator = 1.0 / exposure
        return "1/\(Int(denominator.rounded()))"
    }

    /// Reads `dc:subject` items from a sibling `<stem>.xmp` sidecar. Returns
    /// an empty array when the sidecar is absent or unparseable. Intentionally
    /// lightweight — we only extract the one field the EXIF panel displays.
    private static func readXMPKeywords(imagePath: String) -> [String] {
        let url = URL(fileURLWithPath: imagePath).deletingPathExtension()
            .appendingPathExtension("xmp")
        guard let data = try? Data(contentsOf: url),
              let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        // XMP `dc:subject` is an rdf:Bag of rdf:li strings. A narrow regex
        // captures just the text between the opening <rdf:li …> and closing
        // </rdf:li>, scoped to the first dc:subject block.
        guard let subjectRange = xml.range(of: "<dc:subject>"),
              let endRange = xml.range(of: "</dc:subject>", range: subjectRange.upperBound..<xml.endIndex) else {
            return []
        }
        let block = String(xml[subjectRange.upperBound..<endRange.lowerBound])
        let pattern = #"<rdf:li[^>]*>([^<]+)</rdf:li>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsBlock = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
        return matches.map { xmlUnescape(nsBlock.substring(with: $0.range(at: 1))) }
    }

    private static func xmlUnescape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&lt;",   with: "<")
        out = out.replacingOccurrences(of: "&gt;",   with: ">")
        out = out.replacingOccurrences(of: "&amp;",  with: "&")
        return out
    }

    private static func describeMeteringMode(_ mode: Int?) -> String? {
        switch mode {
        case 1: return "Average"
        case 2: return "Center-weighted"
        case 3: return "Spot"
        case 4: return "Multi-spot"
        case 5: return "Multi-segment"
        case 6: return "Partial"
        default: return mode.map { "Unknown (\($0))" }
        }
    }
}

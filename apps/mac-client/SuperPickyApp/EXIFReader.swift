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
    var offsetTimeOriginal: String?  // raw EXIF offset "+08:00" / "-05:00", nil when camera didn't write the tag
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
        iso == nil && dateTimeOriginal == nil && offsetTimeOriginal == nil &&
        exposureBias == nil &&
        meteringMode == nil && whiteBalance == nil && keywords.isEmpty &&
        latitude == nil && longitude == nil && altitude == nil &&
        city == nil && state == nil && country == nil
    }
}

/// Reads EXIF metadata from image files using ImageIO.
enum EXIFReader {
    /// Caches the ImageIO-parsed base — everything except keywords — by file
    /// path. The RAW file itself doesn't change post-ingest, so this
    /// stays valid for the lifetime of the process. Keywords live in the
    /// sidecar, which the species edit panel rewrites, so they're always
    /// re-read from disk — cheap (tens of µs for a tiny XML file).
    private static let baseCache: NSCache<NSString, CachedBase> = {
        let cache = NSCache<NSString, CachedBase>()
        cache.countLimit = 2000
        return cache
    }()

    private final class CachedBase {
        let data: EXIFData
        init(_ data: EXIFData) { self.data = data }
    }

    /// Returns nil if the file does not exist or cannot be read as an image.
    static func read(from filePath: String) -> EXIFData? {
        let key = filePath as NSString
        var base: EXIFData
        if let cached = baseCache.object(forKey: key) {
            base = cached.data
        } else {
            guard let properties = ImageProperties.load(filePath: filePath) else {
                return nil
            }
            base = parse(properties: properties, imagePath: filePath)
            // ImageIO drops OffsetTimeOriginal for Sony ARW and some other
            // RAWs. Walk the TIFF IFD ourselves as a fallback.
            if base.offsetTimeOriginal == nil {
                base.offsetTimeOriginal = EXIFOffsetReader.readOffsetTimeOriginal(from: filePath)
            }
            baseCache.setObject(CachedBase(base), forKey: key)
        }
        // IPTC keywords (from `base.keywords`) merge with sidecar keywords.
        // The pipeline writes to the sidecar only — RAWs aren't rewritten —
        // so the sidecar is the source of truth for anything we generated.
        var merged = base.keywords
        var seen = Set(base.keywords)
        for keyword in readKeywords(imagePath: filePath) where seen.insert(keyword).inserted {
            merged.append(keyword)
        }
        base.keywords = merged
        return base
    }

    /// Reads `dc:subject` keywords from the sibling `<stem>.xmp` sidecar.
    /// Exposed so callers can refresh keywords after a species edit without
    /// re-parsing the full RAW EXIF.
    static func readKeywords(imagePath: String) -> [String] {
        let url = URL(fileURLWithPath: imagePath).deletingPathExtension()
            .appendingPathExtension("xmp")
        guard let data = try? Data(contentsOf: url),
              let xml = String(data: data, encoding: .utf8) else {
            return []
        }
        return parseXMPKeywords(xml: xml)
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
        data.offsetTimeOriginal = exif?[kCGImagePropertyExifOffsetTimeOriginal as String] as? String

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

        // IPTC keywords baked into the image. Sidecar keywords are merged
        // in by `read(from:)` so callers that only want a keyword refresh
        // don't pay the full ImageIO parse.
        if let kw = iptc?[kCGImagePropertyIPTCKeywords as String] as? [String] {
            data.keywords = kw
        }

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

    /// EXIF exposure time in seconds → display string. Fractional seconds
    /// render as `"1/2000"`; 1+ seconds render as `"2s"` or `"1.5s"`.
    static func formatShutterSpeed(_ exposure: Double) -> String {
        if exposure >= 1.0 {
            if exposure == exposure.rounded() {
                return "\(Int(exposure))s"
            }
            return "\(exposure)s"
        }
        let denominator = 1.0 / exposure
        return "1/\(Int(denominator.rounded()))"
    }

    /// Pure regex-based parse of the first `<dc:subject>` block in an XMP
    /// string. Exposed `internal` so it can be unit-tested without file I/O.
    static func parseXMPKeywords(xml: String) -> [String] {
        guard let subjectRange = xml.range(of: "<dc:subject>"),
              let endRange = xml.range(of: "</dc:subject>",
                                       range: subjectRange.upperBound..<xml.endIndex) else {
            return []
        }
        let block = String(xml[subjectRange.upperBound..<endRange.lowerBound])
        let pattern = #"<rdf:li[^>]*>([^<]+)</rdf:li>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsBlock = block as NSString
        let matches = regex.matches(in: block, range: NSRange(location: 0, length: nsBlock.length))
        return matches.map { xmlUnescape(nsBlock.substring(with: $0.range(at: 1))) }
    }

    /// Reverses the five XML entity replacements emitted by `XMPWriter`.
    /// Order matters: unescape `&amp;` last so `&amp;lt;` round-trips to
    /// `&lt;` rather than becoming `<`.
    static func xmlUnescape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&apos;", with: "'")
        out = out.replacingOccurrences(of: "&quot;", with: "\"")
        out = out.replacingOccurrences(of: "&lt;",   with: "<")
        out = out.replacingOccurrences(of: "&gt;",   with: ">")
        out = out.replacingOccurrences(of: "&amp;",  with: "&")
        return out
    }

    /// EXIF metering-mode code → human label. Falls back to
    /// `"Unknown (<n>)"` for non-standard codes, `nil` when the code itself
    /// is absent (skips the panel row entirely).
    static func describeMeteringMode(_ mode: Int?) -> String? {
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

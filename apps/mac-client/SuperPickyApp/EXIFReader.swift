import Foundation
import CoreGraphics
import ImageIO

/// Metadata extracted from an image file's EXIF, TIFF, and IPTC dictionaries.
///
/// Fields are grouped into nested sections by concern:
/// - ``Camera`` — make, model, lens
/// - ``Exposure`` — focal length, aperture, shutter speed, ISO, etc.
/// - ``Image`` — pixel dimensions and capture date
/// - ``Location`` — GPS coordinates and IPTC place names
/// IPTC keywords stay at the top level since they are commonly accessed
/// independently of any single section.
struct EXIFData: Sendable {
    struct Camera: Sendable {
        var make: String?
        var model: String?
        var lens: String?
    }

    struct Exposure: Sendable {
        var focalLength: Double?       // mm
        var aperture: Double?          // f-number
        var shutterSpeed: String?      // formatted: "1/500" or "2.5s"
        var iso: Int?
        var exposureBias: Double?
        var meteringMode: String?
        var whiteBalance: String?
    }

    struct Image: Sendable {
        var width: Int?
        var height: Int?
        var dateTimeOriginal: String?  // raw EXIF string "2024:03:15 14:30:22"
    }

    struct Location: Sendable {
        var latitude: Double?
        var longitude: Double?
        var altitude: Double?          // meters
        var city: String?
        var state: String?
        var country: String?
    }

    var camera = Camera()
    var exposure = Exposure()
    var image = Image()
    var location = Location()
    var keywords: [String] = []        // IPTC keywords, empty if none

    /// True when no meaningful EXIF metadata is present.
    /// Excludes image width/height since those are always available from the image container.
    var isEmpty: Bool {
        camera.make == nil && camera.model == nil && camera.lens == nil &&
        exposure.focalLength == nil && exposure.aperture == nil && exposure.shutterSpeed == nil &&
        exposure.iso == nil && exposure.exposureBias == nil &&
        exposure.meteringMode == nil && exposure.whiteBalance == nil &&
        image.dateTimeOriginal == nil &&
        location.latitude == nil && location.longitude == nil && location.altitude == nil &&
        location.city == nil && location.state == nil && location.country == nil &&
        keywords.isEmpty
    }
}

/// Reads EXIF metadata from image files using ImageIO.
enum EXIFReader {
    /// Returns nil if the file does not exist or cannot be read as an image.
    static func read(from filePath: String) -> EXIFData? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return nil
        }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exifAux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any]
        let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]

        return EXIFData(
            camera: readCamera(tiff: tiff, exif: exif, exifAux: exifAux),
            exposure: readExposure(exif: exif),
            image: readImage(properties: properties, exif: exif),
            location: readLocation(gps: gps, iptc: iptc),
            keywords: (iptc?[kCGImagePropertyIPTCKeywords as String] as? [String]) ?? []
        )
    }

    // MARK: - Section readers

    private static func readCamera(
        tiff: [String: Any]?,
        exif: [String: Any]?,
        exifAux: [String: Any]?
    ) -> EXIFData.Camera {
        var camera = EXIFData.Camera()
        camera.make = tiff?[kCGImagePropertyTIFFMake as String] as? String
        camera.model = tiff?[kCGImagePropertyTIFFModel as String] as? String
        // Lens: prefer ExifAux, fallback to Exif
        camera.lens = (exifAux?[kCGImagePropertyExifAuxLensModel as String] as? String)
            ?? (exif?[kCGImagePropertyExifLensModel as String] as? String)
        return camera
    }

    private static func readExposure(exif: [String: Any]?) -> EXIFData.Exposure {
        var exposure = EXIFData.Exposure()
        exposure.focalLength = doubleValue(exif, key: kCGImagePropertyExifFocalLength as String)
        exposure.aperture = doubleValue(exif, key: kCGImagePropertyExifFNumber as String)
        exposure.exposureBias = doubleValue(exif, key: kCGImagePropertyExifExposureBiasValue as String)

        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [Any],
           let first = isoArray.first {
            exposure.iso = intValue(first)
        }

        if let exposureTime = doubleValue(exif, key: kCGImagePropertyExifExposureTime as String) {
            exposure.shutterSpeed = formatShutterSpeed(exposureTime)
        }

        if let mode = exif?[kCGImagePropertyExifMeteringMode as String] {
            exposure.meteringMode = describeMeteringMode(intValue(mode))
        }

        if let wb = exif?[kCGImagePropertyExifWhiteBalance as String] {
            exposure.whiteBalance = intValue(wb) == 0 ? "Auto" : "Manual"
        }

        return exposure
    }

    private static func readImage(
        properties: [String: Any],
        exif: [String: Any]?
    ) -> EXIFData.Image {
        var image = EXIFData.Image()
        image.width = properties[kCGImagePropertyPixelWidth as String] as? Int
        image.height = properties[kCGImagePropertyPixelHeight as String] as? Int
        image.dateTimeOriginal = exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String
        return image
    }

    private static func readLocation(
        gps: [String: Any]?,
        iptc: [String: Any]?
    ) -> EXIFData.Location {
        var location = EXIFData.Location()
        if let lat = doubleValue(gps, key: kCGImagePropertyGPSLatitude as String) {
            let ref = gps?[kCGImagePropertyGPSLatitudeRef as String] as? String
            location.latitude = ref == "S" ? -lat : lat
        }
        if let lon = doubleValue(gps, key: kCGImagePropertyGPSLongitude as String) {
            let ref = gps?[kCGImagePropertyGPSLongitudeRef as String] as? String
            location.longitude = ref == "W" ? -lon : lon
        }
        location.altitude = doubleValue(gps, key: kCGImagePropertyGPSAltitude as String)

        location.city = iptc?[kCGImagePropertyIPTCCity as String] as? String
        location.state = iptc?[kCGImagePropertyIPTCProvinceState as String] as? String
        location.country = iptc?[kCGImagePropertyIPTCCountryPrimaryLocationName as String] as? String
        return location
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

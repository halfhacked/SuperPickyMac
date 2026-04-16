// GPSExtractor.swift
//
// Extract latitude/longitude from a photo's EXIF via CGImageSource.
// Mirrors ~/projects/SuperPicky/birdid/bird_identifier.py::extract_gps_from_exif
// for both RAW (ARW, CR3, NEF, …) and JPEG/HEIC. CGImageSource reads
// the GPS IFD natively for all of those formats, so we don't need to
// shell out to exiftool the way the Python path does as a fallback.

import Foundation
import ImageIO

public enum GPSExtractor {

    /// Returns `(lat, lon)` in decimal degrees, or nil if the file has
    /// no GPS IFD / is malformed. Latitude negative in the Southern
    /// hemisphere; longitude negative in the Western hemisphere.
    public static func gps(for fileURL: URL) -> (lat: Double, lon: Double)? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] else {
            return nil
        }
        guard var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        // CGImageSource returns positive magnitudes; apply sign from
        // the ref string. (S, W → negative.)
        if let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String, latRef.uppercased() == "S" {
            lat = -lat
        }
        if let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String, lonRef.uppercased() == "W" {
            lon = -lon
        }
        // Out-of-range values → malformed EXIF; treat as missing.
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            return nil
        }
        // A literal (0, 0) GPS pair almost always means "unset".
        if abs(lat) < 1e-6 && abs(lon) < 1e-6 { return nil }
        return (lat, lon)
    }
}

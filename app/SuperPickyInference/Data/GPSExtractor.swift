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
        return gpsFromCFDict(gps)
    }

    /// Same parsing, but given an already-loaded `[String: Any]` property
    /// dictionary (as produced by `RAWConverter.decode` or
    /// `ImageProperties.load`). Avoids the second
    /// `CGImageSourceCreateWithURL` open when the caller has the props.
    ///
    /// The nested GPS sub-dict bridges to `[String: Any]` when accessed via
    /// the outer `[String: Any]`, so we look it up by its stringified key
    /// and parse it without re-keying the parent dictionary.
    public static func gps(fromProperties props: [String: Any]) -> (lat: Double, lon: Double)? {
        let gpsKey = kCGImagePropertyGPSDictionary as String
        guard let gps = props[gpsKey] as? [String: Any] else { return nil }
        return gpsFromSwiftDict(gps)
    }

    private static func gpsFromCFDict(_ gps: [CFString: Any]) -> (lat: Double, lon: Double)? {
        guard var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
              var lon = gps[kCGImagePropertyGPSLongitude] as? Double else {
            return nil
        }
        if let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String, latRef.uppercased() == "S" {
            lat = -lat
        }
        if let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String, lonRef.uppercased() == "W" {
            lon = -lon
        }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            return nil
        }
        if abs(lat) < 1e-6 && abs(lon) < 1e-6 { return nil }
        return (lat, lon)
    }

    private static func gpsFromSwiftDict(_ gps: [String: Any]) -> (lat: Double, lon: Double)? {
        let latKey = kCGImagePropertyGPSLatitude as String
        let lonKey = kCGImagePropertyGPSLongitude as String
        let latRefKey = kCGImagePropertyGPSLatitudeRef as String
        let lonRefKey = kCGImagePropertyGPSLongitudeRef as String
        guard var lat = gps[latKey] as? Double,
              var lon = gps[lonKey] as? Double else {
            return nil
        }
        if let latRef = gps[latRefKey] as? String, latRef.uppercased() == "S" {
            lat = -lat
        }
        if let lonRef = gps[lonRefKey] as? String, lonRef.uppercased() == "W" {
            lon = -lon
        }
        guard (-90.0...90.0).contains(lat), (-180.0...180.0).contains(lon) else {
            return nil
        }
        if abs(lat) < 1e-6 && abs(lon) < 1e-6 { return nil }
        return (lat, lon)
    }
}

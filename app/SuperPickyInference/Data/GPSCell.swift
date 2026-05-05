import Foundation

/// 0.1° grid cell key for GPS coordinates. Shared by ReverseGeocoder,
/// SpeciesFilter, and PipelineCoordinator for per-cell caching and dedup.
/// A 0.1° cell is ~11 km, close enough to Avonet's 1° cells for regional
/// species filtering and close enough for CLGeocoder placemark reuse.
public enum GPSCell {
    public static func key(lat: Double, lon: Double) -> UInt64 {
        let latK = Int32((lat * 10).rounded())
        let lonK = Int32((lon * 10).rounded())
        return (UInt64(bitPattern: Int64(latK)) & 0xFFFFFFFF) << 32
            | (UInt64(bitPattern: Int64(lonK)) & 0xFFFFFFFF)
    }
}

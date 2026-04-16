// RegionBounds.swift
//
// Country / state bounding-box lookup ported verbatim from
// ~/projects/SuperPicky/birdid/avonet_filter.py::REGION_BOUNDS.
// Used by SpeciesFilter when Avonet's 1×1° distribution grid has no
// match and we need to fall back to eBird's per-country species list.
//
// Keep this file in sync with the Python dict. The source of truth
// is the Python file; regenerate the Swift entries with:
//   cd ~/projects/SuperPicky && .venv/bin/python - <<EOF
//   from birdid.avonet_filter import REGION_BOUNDS
//   for code, (s, n, w, e) in REGION_BOUNDS.items():
//       print(f'    "{code}": CountryBBox(south: {s}, north: {n}, west: {w}, east: {e}),')
//   EOF

import Foundation

public struct CountryBBox: Sendable {
    public let south: Double
    public let north: Double
    public let west: Double
    public let east: Double
    public var area: Double { (north - south) * (east - west) }

    public func contains(lat: Double, lon: Double) -> Bool {
        south <= lat && lat <= north && west <= lon && lon <= east
    }
}

public enum RegionBounds {
    /// Continent-scale and global codes — skipped when resolving a
    /// specific country from GPS (they would shadow small countries).
    /// Matches Python _SKIP in avonet_filter.py::_detect_country_from_gps.
    public static let continentCodes: Set<String> = [
        "GLOBAL", "AF", "AS", "EU", "NA", "SA", "OC",
    ]

    public static let bounds: [String: CountryBBox] = [
    "GLOBAL": CountryBBox(south: -90, north: 90, west: -180, east: 180),
    "AF": CountryBBox(south: -35, north: 37, west: -17, east: 51),
    "AS": CountryBBox(south: -10, north: 81, west: 26, east: 170),
    "EU": CountryBBox(south: 34, north: 71, west: -25, east: 45),
    "NA": CountryBBox(south: 14, north: 83, west: -168, east: -52),
    "SA": CountryBBox(south: -56, north: 13, west: -81, east: -34),
    "OC": CountryBBox(south: -47, north: -10, west: 110, east: 180),
    "AU": CountryBBox(south: -44, north: -10, west: 112, east: 155),
    "NZ": CountryBBox(south: -47.5, north: -34, west: 166, east: 179),
    "CN": CountryBBox(south: 18, north: 54, west: 73, east: 135),
    "JP": CountryBBox(south: 24, north: 46, west: 122, east: 154),
    "KR": CountryBBox(south: 33, north: 43, west: 124, east: 132),
    "TW": CountryBBox(south: 21.5, north: 25.5, west: 119, east: 122.5),
    "HK": CountryBBox(south: 22.1, north: 22.6, west: 113.8, east: 114.5),
    "TH": CountryBBox(south: 5.5, north: 20.5, west: 97.5, east: 105.5),
    "MY": CountryBBox(south: 0.5, north: 7.5, west: 99.5, east: 119.5),
    "SG": CountryBBox(south: 1.1, north: 1.5, west: 103.6, east: 104.1),
    "ID": CountryBBox(south: -11, north: 6, west: 95, east: 141),
    "PH": CountryBBox(south: 4.5, north: 21, west: 116, east: 127),
    "VN": CountryBBox(south: 8, north: 23.5, west: 102, east: 110),
    "IN": CountryBBox(south: 6, north: 36, west: 68, east: 98),
    "LK": CountryBBox(south: 5, north: 10, west: 79, east: 82),
    "NP": CountryBBox(south: 26, north: 31, west: 80, east: 88),
    "MN": CountryBBox(south: 41, north: 52, west: 87, east: 120),
    "RU": CountryBBox(south: 41, north: 82, west: 19, east: 180),
    "US": CountryBBox(south: 24, north: 49, west: -125, east: -66),
    "CA": CountryBBox(south: 42, north: 83, west: -141, east: -52),
    "MX": CountryBBox(south: 14, north: 33, west: -118, east: -86),
    "BR": CountryBBox(south: -34, north: 5.5, west: -74, east: -34),
    "AR": CountryBBox(south: -55, north: -21, west: -73, east: -53),
    "CL": CountryBBox(south: -56, north: -17, west: -76, east: -66),
    "CO": CountryBBox(south: -4.5, north: 13, west: -79, east: -66),
    "PE": CountryBBox(south: -18.5, north: 0, west: -81, east: -68),
    "EC": CountryBBox(south: -5, north: 2, west: -81, east: -75),
    "CR": CountryBBox(south: 8, north: 11.5, west: -86, east: -82.5),
    "GB": CountryBBox(south: 49, north: 61, west: -8, east: 2),
    "FR": CountryBBox(south: 41, north: 51.5, west: -5, east: 10),
    "DE": CountryBBox(south: 47, north: 55.5, west: 5.5, east: 15.5),
    "ES": CountryBBox(south: 35.5, north: 44, west: -10, east: 4.5),
    "IT": CountryBBox(south: 36, north: 47.5, west: 6.5, east: 18.5),
    "NO": CountryBBox(south: 57.5, north: 71.5, west: 4.5, east: 31.5),
    "SE": CountryBBox(south: 55, north: 69.5, west: 10.5, east: 24.5),
    "FI": CountryBBox(south: 59.5, north: 70.5, west: 19.5, east: 31.5),
    "PL": CountryBBox(south: 49, north: 55, west: 14, east: 24.5),
    "TR": CountryBBox(south: 35.5, north: 42.5, west: 25.5, east: 45),
    "PT": CountryBBox(south: 36, north: 42, west: -10, east: -6),
    "NL": CountryBBox(south: 50, north: 54, west: 3, east: 8),
    "CH": CountryBBox(south: 45, north: 48, west: 5, east: 11),
    "GR": CountryBBox(south: 34, north: 42, west: 19, east: 29),
    "UA": CountryBBox(south: 44, north: 53, west: 22, east: 41),
    "MG": CountryBBox(south: -26, north: -11, west: 43, east: 51),
    "ZA": CountryBBox(south: -35, north: -22, west: 16.5, east: 33),
    "KE": CountryBBox(south: -5, north: 5, west: 33.5, east: 42),
    "TZ": CountryBBox(south: -12, north: -1, west: 29, east: 41),
    "EG": CountryBBox(south: 22, north: 32, west: 24.5, east: 37),
    "MA": CountryBBox(south: 27, north: 36, west: -13, east: -1),
    "AU-QLD": CountryBBox(south: -29, north: -10, west: 138, east: 154),
    "AU-NSW": CountryBBox(south: -37.5, north: -28, west: 141, east: 154),
    "AU-VIC": CountryBBox(south: -39.2, north: -34, west: 141, east: 150),
    "AU-TAS": CountryBBox(south: -43.7, north: -39.5, west: 143.5, east: 148.5),
    "AU-SA": CountryBBox(south: -38, north: -26, west: 129, east: 141),
    "AU-WA": CountryBBox(south: -35, north: -13.5, west: 112.5, east: 129),
    "AU-NT": CountryBBox(south: -26, north: -10.5, west: 129, east: 138),
    "AU-ACT": CountryBBox(south: -35.95, north: -35.1, west: 148.75, east: 149.4),
    "US-AL": CountryBBox(south: 30, north: 35, west: -88.5, east: -84.9),
    "US-AK": CountryBBox(south: 51, north: 72, west: -168, east: -130),
    "US-AZ": CountryBBox(south: 31.3, north: 37, west: -114.8, east: -109),
    "US-AR": CountryBBox(south: 33, north: 36.5, west: -94.6, east: -89.6),
    "US-CA": CountryBBox(south: 32.5, north: 42, west: -124.5, east: -114),
    "US-CO": CountryBBox(south: 37, north: 41, west: -109, east: -102),
    "US-CT": CountryBBox(south: 40.9, north: 42.1, west: -73.7, east: -71.8),
    "US-DE": CountryBBox(south: 38.4, north: 39.8, west: -75.8, east: -75),
    "US-FL": CountryBBox(south: 24.4, north: 31, west: -87.7, east: -80),
    "US-GA": CountryBBox(south: 30.4, north: 35, west: -85.6, east: -80.8),
    "US-HI": CountryBBox(south: 18.9, north: 22.2, west: -160.3, east: -154.8),
    "US-ID": CountryBBox(south: 42, north: 49, west: -117.2, east: -111),
    "US-IL": CountryBBox(south: 36.9, north: 42.5, west: -91.5, east: -87.5),
    "US-IN": CountryBBox(south: 37.8, north: 41.8, west: -88.1, east: -84.8),
    "US-IA": CountryBBox(south: 40.4, north: 43.5, west: -96.6, east: -90.1),
    "US-KS": CountryBBox(south: 37, north: 40, west: -102.1, east: -94.6),
    "US-KY": CountryBBox(south: 36.5, north: 39.2, west: -89.6, east: -81.9),
    "US-LA": CountryBBox(south: 28.9, north: 33.1, west: -94.1, east: -88.8),
    "US-ME": CountryBBox(south: 43.1, north: 47.5, west: -71.1, east: -66.9),
    "US-MD": CountryBBox(south: 37.9, north: 39.7, west: -79.5, east: -75),
    "US-MA": CountryBBox(south: 41.2, north: 42.9, west: -73.5, east: -69.9),
    "US-MI": CountryBBox(south: 41.7, north: 48.3, west: -90.4, east: -82.4),
    "US-MN": CountryBBox(south: 43.5, north: 49.4, west: -97.2, east: -89.5),
    "US-MS": CountryBBox(south: 30, north: 35, west: -91.7, east: -88.1),
    "US-MO": CountryBBox(south: 36, north: 40.6, west: -95.8, east: -89.1),
    "US-MT": CountryBBox(south: 44.4, north: 49, west: -116.1, east: -104),
    "US-NE": CountryBBox(south: 40, north: 43, west: -104.1, east: -95.3),
    "US-NV": CountryBBox(south: 35, north: 42, west: -120, east: -114),
    "US-NH": CountryBBox(south: 42.7, north: 45.3, west: -72.6, east: -70.7),
    "US-NJ": CountryBBox(south: 38.9, north: 41.4, west: -75.6, east: -73.9),
    "US-NM": CountryBBox(south: 31.3, north: 37, west: -109.1, east: -103),
    "US-NY": CountryBBox(south: 40.5, north: 45.1, west: -79.8, east: -71.9),
    "US-NC": CountryBBox(south: 33.8, north: 36.6, west: -84.3, east: -75.5),
    "US-ND": CountryBBox(south: 45.9, north: 49, west: -104.1, east: -96.6),
    "US-OH": CountryBBox(south: 38.4, north: 42, west: -84.8, east: -80.5),
    "US-OK": CountryBBox(south: 33.6, north: 37, west: -103, east: -94.4),
    "US-OR": CountryBBox(south: 41.9, north: 46.3, west: -124.6, east: -116.5),
    "US-PA": CountryBBox(south: 39.7, north: 42.3, west: -80.5, east: -74.7),
    "US-RI": CountryBBox(south: 41.1, north: 42.1, west: -71.9, east: -71.1),
    "US-SC": CountryBBox(south: 32, north: 35.2, west: -83.4, east: -78.5),
    "US-SD": CountryBBox(south: 42.5, north: 45.9, west: -104.1, east: -96.4),
    "US-TN": CountryBBox(south: 35, north: 36.7, west: -90.3, east: -81.6),
    "US-TX": CountryBBox(south: 25.8, north: 36.5, west: -106.6, east: -93.5),
    "US-UT": CountryBBox(south: 37, north: 42, west: -114.1, east: -109),
    "US-VT": CountryBBox(south: 42.7, north: 45.1, west: -73.4, east: -71.5),
    "US-VA": CountryBBox(south: 36.5, north: 39.5, west: -83.7, east: -75.2),
    "US-WA": CountryBBox(south: 45.5, north: 49, west: -124.8, east: -116.9),
    "US-WV": CountryBBox(south: 37.2, north: 40.6, west: -82.7, east: -77.7),
    "US-WI": CountryBBox(south: 42.5, north: 47.1, west: -92.9, east: -86.8),
    "US-WY": CountryBBox(south: 41, north: 45, west: -111.1, east: -104),
    "CN-11": CountryBBox(south: 39.4, north: 41.1, west: 115.4, east: 117.7),
    "CN-12": CountryBBox(south: 38.6, north: 40.3, west: 116.7, east: 118.1),
    "CN-13": CountryBBox(south: 36, north: 42.7, west: 113.5, east: 119.8),
    "CN-14": CountryBBox(south: 34.6, north: 40.7, west: 110.2, east: 114.6),
    "CN-15": CountryBBox(south: 37.5, north: 53.3, west: 97.2, east: 126.1),
    "CN-21": CountryBBox(south: 38.7, north: 43.5, west: 118.8, east: 125.7),
    "CN-22": CountryBBox(south: 41.2, north: 46, west: 121.6, east: 131.3),
    "CN-23": CountryBBox(south: 43.4, north: 53.6, west: 121.1, east: 135.1),
    "CN-31": CountryBBox(south: 30.7, north: 31.9, west: 120.8, east: 122),
    "CN-32": CountryBBox(south: 30.8, north: 35.1, west: 116.4, east: 121.9),
    "CN-33": CountryBBox(south: 27.1, north: 31.2, west: 118.1, east: 122.9),
    "CN-34": CountryBBox(south: 29.4, north: 34.7, west: 114.9, east: 119.9),
    "CN-35": CountryBBox(south: 23.5, north: 28.3, west: 115.8, east: 120.7),
    "CN-36": CountryBBox(south: 24.5, north: 30.1, west: 113.6, east: 118.5),
    "CN-37": CountryBBox(south: 34.4, north: 38.3, west: 114.8, east: 122.7),
    "CN-41": CountryBBox(south: 31.4, north: 36.4, west: 110.4, east: 116.7),
    "CN-42": CountryBBox(south: 29.1, north: 33.2, west: 108.4, east: 116.1),
    "CN-43": CountryBBox(south: 24.6, north: 30.1, west: 108.8, east: 114.3),
    "CN-44": CountryBBox(south: 20.2, north: 25.5, west: 109.7, east: 117.3),
    "CN-45": CountryBBox(south: 20.9, north: 26.4, west: 104.5, east: 112.1),
    "CN-46": CountryBBox(south: 18.1, north: 20.2, west: 108.4, east: 111.2),
    "CN-50": CountryBBox(south: 28.2, north: 32.2, west: 105.3, east: 110.2),
    "CN-51": CountryBBox(south: 26, north: 34.3, west: 97.4, east: 108.5),
    "CN-52": CountryBBox(south: 24.6, north: 29.2, west: 103.6, east: 109.6),
    "CN-53": CountryBBox(south: 21.1, north: 29.3, west: 97.5, east: 106.2),
    "CN-54": CountryBBox(south: 26.8, north: 36.5, west: 78.4, east: 99.1),
    "CN-61": CountryBBox(south: 31.7, north: 39.6, west: 105.5, east: 111.3),
    "CN-62": CountryBBox(south: 32.6, north: 42.8, west: 92.4, east: 108.7),
    "CN-63": CountryBBox(south: 31.6, north: 39.2, west: 89.4, east: 103.1),
    "CN-64": CountryBBox(south: 35.2, north: 39.4, west: 104.3, east: 107.7),
    "CN-65": CountryBBox(south: 34.3, north: 49.2, west: 73.5, east: 96.4),
    ]

    /// Resolve the smallest country whose bounding box contains the
    /// given GPS point. Continent codes are excluded so small countries
    /// aren't shadowed by wide fallback regions. Returns nil if no
    /// country matches — caller should treat that as "use global".
    public static func smallestContaining(lat: Double, lon: Double) -> String? {
        var best: (code: String, area: Double)?
        for (code, bbox) in bounds {
            guard !continentCodes.contains(code) else { continue }
            guard bbox.contains(lat: lat, lon: lon) else { continue }
            if best == nil || bbox.area < best!.area {
                best = (code, bbox.area)
            }
        }
        return best?.code
    }
}

import Foundation
import Testing
@testable import SuperPickyInference

@Suite("RegionBounds")
struct RegionBoundsTests {

    @Test("smallestContaining(44.5, -123.0) resolves inside the US")
    func usPortland() {
        // Willamette Valley, Oregon. The Python REGION_BOUNDS includes
        // per-state bboxes (US-OR, US-CA, …) alongside the US country
        // bbox, so the winner is whichever state contains the point —
        // all that matters for parity is that a US-prefixed code comes
        // back, not a continent or another country.
        let code = RegionBounds.smallestContaining(lat: 44.5, lon: -123.0)
        #expect(code != nil)
        if let code {
            #expect(code == "US" || code.hasPrefix("US-"))
        }
    }

    @Test("Continent codes are excluded from resolution")
    func continentCodesExcluded() {
        // The continent bounding boxes (NA, SA, AF, AS, EU, OC, GLOBAL)
        // must never be returned — they'd always shadow countries.
        let result = RegionBounds.smallestContaining(lat: 0.0, lon: 0.0)
        if let code = result {
            #expect(!RegionBounds.continentCodes.contains(code),
                    "smallestContaining returned continent code \(code)")
        }
    }

    @Test("Coordinates in the middle of an ocean return nil")
    func openOceanReturnsNil() {
        // Mid-Pacific — outside every land-based country bbox.
        // The dataset has a handful of overlapping island-nation bboxes
        // (e.g. Kiribati), so the only truly-empty check is deep ocean
        // far south of Hawaii.
        #expect(RegionBounds.smallestContaining(lat: -30.0, lon: -150.0) == nil)
    }

    @Test("Smallest containing box wins when multiple bboxes overlap")
    func smallestWins() throws {
        // Washington DC — (38.9, -77.0). Contained by the US country
        // bbox, the NA continent bbox, and whichever state bbox wraps
        // it (MD, since DC falls inside Maryland's rectangle). The
        // winner must be a state (smallest area); NA must be filtered
        // out by the continent-code skip.
        let result = RegionBounds.smallestContaining(lat: 38.9, lon: -77.0)
        let code = try #require(result)
        #expect(code.hasPrefix("US"))
        // Must not return a continent code.
        #expect(!RegionBounds.continentCodes.contains(code))
    }

    @Test("All non-continent entries have valid bounds")
    func allEntriesValid() {
        for (code, bbox) in RegionBounds.bounds {
            #expect(bbox.south <= bbox.north, "\(code): south > north")
            #expect(bbox.west <= bbox.east, "\(code): west > east")
            #expect(bbox.south >= -90 && bbox.north <= 90, "\(code): lat out of range")
            #expect(bbox.west >= -180 && bbox.east <= 180, "\(code): lon out of range")
        }
    }

    @Test("Bounds contains check is inclusive on all four edges")
    func containsInclusive() {
        let bbox = CountryBBox(south: 10.0, north: 20.0, west: -5.0, east: 5.0)
        #expect(bbox.contains(lat: 10.0, lon: -5.0))  // SW corner
        #expect(bbox.contains(lat: 20.0, lon: 5.0))   // NE corner
        #expect(bbox.contains(lat: 15.0, lon: 0.0))   // interior
        #expect(!bbox.contains(lat: 9.9, lon: 0.0))   // just south
        #expect(!bbox.contains(lat: 15.0, lon: 5.1))  // just east
    }
}

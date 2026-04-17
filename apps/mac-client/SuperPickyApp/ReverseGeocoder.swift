// ReverseGeocoder.swift
//
// Resolve GPS → (city, state, country, countryCode, sublocation) via
// CoreLocation. The underlying `CLGeocoder.reverseGeocodeLocation` is a
// networked MapKit call (~100–500 ms per unique cell and rate-limited by
// Apple), so per-photo resolution is unworkable on a 877-photo shoot —
// everything here exists to make it effectively free after the first hit.
//
// Design:
//   - Cell-keyed cache (0.1° ≈ 11 km, same grid the SpeciesFilter cache
//     uses). A single bird shoot rarely crosses cells, so one CLGeocoder
//     round-trip per folder is typical.
//   - In-flight coalescing: when six concurrent photos all miss the same
//     cell at once, only one of them fires CLGeocoder; the other five
//     `await` the same task.
//   - Negative caching: cells that fail to resolve (offline, rate-limited,
//     no placemark) store `nil` so we don't retry them 876 times.
//
// Ports preen's `reverse_geocode()` from `preen/src/preen/folder.py`;
// same fields, different glue.

import Foundation
import CoreLocation

public struct LocationInfo: Sendable, Equatable {
    public let city: String?
    public let state: String?
    public let country: String?
    public let countryCode: String?
    public let sublocation: String?

    public var isEmpty: Bool {
        city == nil && state == nil && country == nil && countryCode == nil && sublocation == nil
    }
}

public actor ReverseGeocoder {
    // Cached result per cell. The outer `Optional` lets us distinguish
    // "not yet resolved" (absent) from "resolved to nothing" (present, nil).
    private var cache: [UInt64: LocationInfo?] = [:]
    // Coalesce concurrent resolutions of the same cell — six slots can all
    // ask for the same placemark before any of them finishes.
    private var inflight: [UInt64: Task<LocationInfo?, Never>] = [:]

    public init() {}

    private static func cellKey(lat: Double, lon: Double) -> UInt64 {
        let latK = Int32((lat * 10).rounded())
        let lonK = Int32((lon * 10).rounded())
        return (UInt64(bitPattern: Int64(latK)) & 0xFFFFFFFF) << 32
            | (UInt64(bitPattern: Int64(lonK)) & 0xFFFFFFFF)
    }

    public func resolve(lat: Double, lon: Double) async -> LocationInfo? {
        let key = Self.cellKey(lat: lat, lon: lon)
        if let cached = cache[key] { return cached }
        if let task = inflight[key] { return await task.value }
        let task = Task { await Self.runCLGeocoder(lat: lat, lon: lon) }
        inflight[key] = task
        let result = await task.value
        cache[key] = result
        inflight.removeValue(forKey: key)
        return result
    }

    private static func runCLGeocoder(lat: Double, lon: Double) async -> LocationInfo? {
        let loc = CLLocation(latitude: lat, longitude: lon)
        let geocoder = CLGeocoder()
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(loc)
            guard let p = placemarks.first else { return nil }
            let info = LocationInfo(
                city: p.locality,
                state: p.administrativeArea,
                country: p.country,
                countryCode: p.isoCountryCode,
                sublocation: p.subLocality
            )
            return info.isEmpty ? nil : info
        } catch {
            return nil
        }
    }
}

import Foundation

/// Pure-string formatting helpers for displaying EXIF metadata.
/// Kept free of SwiftUI so it can be unit-tested and reused outside views.
enum ExifFormatters {
    /// Renders a Double as an integer when whole, otherwise with one decimal place.
    static func formatNumber(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    /// Combines shutter speed, aperture, and ISO Lightroom-style: "1/2000 at f/6.3, ISO 1600".
    static func formatExposure(_ data: EXIFData) -> String {
        var parts: [String] = []
        if let shutter = data.exposure.shutterSpeed { parts.append(shutter) }
        if let aperture = data.exposure.aperture { parts.append("f/\(formatNumber(aperture))") }
        if let iso = data.exposure.iso { parts.append("ISO \(iso)") }
        if parts.isEmpty { return "—" }
        if data.exposure.shutterSpeed != nil, data.exposure.aperture != nil {
            let shutter = parts.removeFirst()
            let aperture = parts.removeFirst()
            var result = "\(shutter) at \(aperture)"
            if !parts.isEmpty { result += ", \(parts.joined(separator: ", "))" }
            return result
        }
        return parts.joined(separator: ", ")
    }

    /// Converts a raw EXIF date string ("2025:03:15 07:30:22") to "Mar 15, 2025  07:30".
    static func formatDate(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard let datePart = parts.first else { return raw }
        let dateComponents = datePart.split(separator: ":")
        guard dateComponents.count == 3,
              let year = Int(dateComponents[0]),
              let month = Int(dateComponents[1]),
              let day = Int(dateComponents[2]) else { return raw }

        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                      "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let monthName = month >= 1 && month <= 12 ? months[month] : "\(month)"

        var result = "\(monthName) \(day), \(year)"
        if parts.count > 1 {
            let timeParts = parts[1].split(separator: ":")
            if timeParts.count >= 2 {
                result += "  \(timeParts[0]):\(timeParts[1])"
            }
        }
        return result
    }

    /// Joins city/state/country into a single comma-separated location string.
    static func formatLocation(_ data: EXIFData) -> String? {
        let parts = [data.location.city, data.location.state, data.location.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Formats GPS coordinates with hemisphere suffixes: "37.7749° N, 122.4194° W".
    static func formatCoordinates(_ data: EXIFData) -> String? {
        guard let lat = data.location.latitude, let lon = data.location.longitude else { return nil }
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.4f\u{00B0} %@, %.4f\u{00B0} %@",
                      abs(lat), latDir, abs(lon), lonDir)
    }
}

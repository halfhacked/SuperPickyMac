import Foundation

/// Pure string formatters for EXIF values. Lives outside `ExifPanelView`
/// so each helper can be unit-tested in isolation.
enum ExifFormatters {

    /// Integer when the value is a whole number, otherwise one decimal.
    /// `70` → `"70"`, `2.8` → `"2.8"`, `6.30` → `"6.3"`.
    static func number(_ value: Double) -> String {
        if value == value.rounded() {
            return "\(Int(value))"
        }
        return String(format: "%.1f", value)
    }

    /// Lightroom-style exposure triplet, e.g. `"1/2000 at f/6.3, ISO 1600"`.
    /// Returns the em-dash `"—"` when all three fields are nil. When shutter
    /// + aperture are present, they're combined with "at"; a trailing ISO is
    /// appended after a comma. Otherwise just joins whatever's available.
    static func exposure(shutterSpeed: String?, aperture: Double?, iso: Int?) -> String {
        var parts: [String] = []
        if let shutterSpeed { parts.append(shutterSpeed) }
        if let aperture { parts.append("f/\(number(aperture))") }
        if let iso { parts.append("ISO \(iso)") }
        if parts.isEmpty { return "—" }
        if parts.count >= 2, shutterSpeed != nil, aperture != nil {
            let shutter = parts.removeFirst()
            let apertureText = parts.removeFirst()
            var result = "\(shutter) at \(apertureText)"
            if !parts.isEmpty { result += ", \(parts.joined(separator: ", "))" }
            return result
        }
        return parts.joined(separator: ", ")
    }

    /// EXIF `"yyyy:MM:dd HH:mm:ss"` → localized medium date + short time in
    /// the supplied `locale`. Returns the raw string unchanged if parsing
    /// fails (some EXIF files use alternate formats).
    static func date(_ raw: String, locale: Locale) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        parser.locale = Locale(identifier: "en_US_POSIX")
        guard let date = parser.date(from: raw) else { return raw }

        let display = DateFormatter()
        display.locale = locale
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }

    /// Joins non-nil city / state / country with `", "`. Returns nil when
    /// none of the three is available.
    static func location(city: String?, state: String?, country: String?) -> String? {
        let parts = [city, state, country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// DMS-style degree string, e.g. `"47.6062° N, 122.3321° W"`.
    /// Returns nil when either coordinate is missing.
    static func coordinates(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        let latDir = latitude >= 0 ? "N" : "S"
        let lonDir = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f\u{00B0} %@, %.4f\u{00B0} %@",
                      abs(latitude), latDir, abs(longitude), lonDir)
    }
}

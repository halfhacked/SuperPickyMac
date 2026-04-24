import Foundation

struct TimezoneEntry: Identifiable, Hashable {
    let id: String
    let city: String
    let region: String
    let zone: String
    let latitude: Double
    let longitude: Double
}

enum TimezoneCatalog {
    static let all: [TimezoneEntry] = [
        TimezoneEntry(id: "sfo", city: "San Francisco",     region: "California, USA",  zone: "America/Los_Angeles",             latitude:  37.77, longitude: -122.42),
        TimezoneEntry(id: "lax", city: "Los Angeles",       region: "California, USA",  zone: "America/Los_Angeles",             latitude:  34.05, longitude: -118.24),
        TimezoneEntry(id: "sea", city: "Seattle",           region: "Washington, USA",  zone: "America/Los_Angeles",             latitude:  47.60, longitude: -122.33),
        TimezoneEntry(id: "den", city: "Denver",            region: "Colorado, USA",    zone: "America/Denver",                  latitude:  39.74, longitude: -104.99),
        TimezoneEntry(id: "chi", city: "Chicago",           region: "Illinois, USA",    zone: "America/Chicago",                 latitude:  41.88, longitude:  -87.63),
        TimezoneEntry(id: "mex", city: "Mexico City",       region: "Mexico",           zone: "America/Mexico_City",             latitude:  19.43, longitude:  -99.13),
        TimezoneEntry(id: "nyc", city: "New York",          region: "New York, USA",    zone: "America/New_York",                latitude:  40.71, longitude:  -74.01),
        TimezoneEntry(id: "mia", city: "Miami",             region: "Florida, USA",     zone: "America/New_York",                latitude:  25.76, longitude:  -80.19),
        TimezoneEntry(id: "tor", city: "Toronto",           region: "Ontario, Canada",  zone: "America/Toronto",                 latitude:  43.65, longitude:  -79.38),
        TimezoneEntry(id: "bog", city: "Bogotá",            region: "Colombia",         zone: "America/Bogota",                  latitude:   4.71, longitude:  -74.07),
        TimezoneEntry(id: "sao", city: "São Paulo",         region: "Brazil",           zone: "America/Sao_Paulo",               latitude: -23.55, longitude:  -46.63),
        TimezoneEntry(id: "bue", city: "Buenos Aires",      region: "Argentina",        zone: "America/Argentina/Buenos_Aires",  latitude: -34.60, longitude:  -58.38),
        TimezoneEntry(id: "lon", city: "London",            region: "United Kingdom",   zone: "Europe/London",                   latitude:  51.51, longitude:   -0.13),
        TimezoneEntry(id: "dub", city: "Dublin",            region: "Ireland",          zone: "Europe/Dublin",                   latitude:  53.35, longitude:   -6.26),
        TimezoneEntry(id: "par", city: "Paris",             region: "France",           zone: "Europe/Paris",                    latitude:  48.86, longitude:    2.35),
        TimezoneEntry(id: "ams", city: "Amsterdam",         region: "Netherlands",      zone: "Europe/Amsterdam",                latitude:  52.37, longitude:    4.90),
        TimezoneEntry(id: "ber", city: "Berlin",            region: "Germany",          zone: "Europe/Berlin",                   latitude:  52.52, longitude:   13.40),
        TimezoneEntry(id: "mad", city: "Madrid",            region: "Spain",            zone: "Europe/Madrid",                   latitude:  40.42, longitude:   -3.70),
        TimezoneEntry(id: "rom", city: "Rome",              region: "Italy",            zone: "Europe/Rome",                     latitude:  41.90, longitude:   12.50),
        TimezoneEntry(id: "sto", city: "Stockholm",         region: "Sweden",           zone: "Europe/Stockholm",                latitude:  59.33, longitude:   18.07),
        TimezoneEntry(id: "mos", city: "Moscow",            region: "Russia",           zone: "Europe/Moscow",                   latitude:  55.76, longitude:   37.62),
        TimezoneEntry(id: "ist", city: "Istanbul",          region: "Türkiye",          zone: "Europe/Istanbul",                 latitude:  41.01, longitude:   28.98),
        TimezoneEntry(id: "cai", city: "Cairo",             region: "Egypt",            zone: "Africa/Cairo",                    latitude:  30.04, longitude:   31.24),
        TimezoneEntry(id: "lag", city: "Lagos",             region: "Nigeria",          zone: "Africa/Lagos",                    latitude:   6.52, longitude:    3.38),
        TimezoneEntry(id: "nai", city: "Nairobi",           region: "Kenya",            zone: "Africa/Nairobi",                  latitude:  -1.29, longitude:   36.82),
        TimezoneEntry(id: "jnb", city: "Johannesburg",      region: "South Africa",     zone: "Africa/Johannesburg",             latitude: -26.20, longitude:   28.05),
        TimezoneEntry(id: "dxb", city: "Dubai",             region: "UAE",              zone: "Asia/Dubai",                      latitude:  25.20, longitude:   55.27),
        TimezoneEntry(id: "thr", city: "Tehran",            region: "Iran",             zone: "Asia/Tehran",                     latitude:  35.69, longitude:   51.39),
        TimezoneEntry(id: "kar", city: "Karachi",           region: "Pakistan",         zone: "Asia/Karachi",                    latitude:  24.86, longitude:   67.00),
        TimezoneEntry(id: "del", city: "Delhi",             region: "India",            zone: "Asia/Kolkata",                    latitude:  28.61, longitude:   77.21),
        TimezoneEntry(id: "bom", city: "Mumbai",            region: "India",            zone: "Asia/Kolkata",                    latitude:  19.08, longitude:   72.88),
        TimezoneEntry(id: "blr", city: "Bengaluru",         region: "India",            zone: "Asia/Kolkata",                    latitude:  12.97, longitude:   77.59),
        TimezoneEntry(id: "bkk", city: "Bangkok",           region: "Thailand",         zone: "Asia/Bangkok",                    latitude:  13.76, longitude:  100.50),
        TimezoneEntry(id: "sgn", city: "Ho Chi Minh City",  region: "Vietnam",          zone: "Asia/Ho_Chi_Minh",                latitude:  10.82, longitude:  106.63),
        TimezoneEntry(id: "sin", city: "Singapore",         region: "Singapore",        zone: "Asia/Singapore",                  latitude:   1.35, longitude:  103.82),
        TimezoneEntry(id: "kul", city: "Kuala Lumpur",      region: "Malaysia",         zone: "Asia/Kuala_Lumpur",               latitude:   3.14, longitude:  101.69),
        TimezoneEntry(id: "jak", city: "Jakarta",           region: "Indonesia",        zone: "Asia/Jakarta",                    latitude:  -6.21, longitude:  106.85),
        TimezoneEntry(id: "hkg", city: "Hong Kong",         region: "Hong Kong SAR",    zone: "Asia/Hong_Kong",                  latitude:  22.32, longitude:  114.17),
        TimezoneEntry(id: "tpe", city: "Taipei",            region: "Taiwan",           zone: "Asia/Taipei",                     latitude:  25.03, longitude:  121.57),
        TimezoneEntry(id: "sha", city: "Shanghai",          region: "China",            zone: "Asia/Shanghai",                   latitude:  31.23, longitude:  121.47),
        TimezoneEntry(id: "pek", city: "Beijing",           region: "China",            zone: "Asia/Shanghai",                   latitude:  39.90, longitude:  116.41),
        TimezoneEntry(id: "sel", city: "Seoul",             region: "South Korea",      zone: "Asia/Seoul",                      latitude:  37.57, longitude:  126.98),
        TimezoneEntry(id: "tyo", city: "Tokyo",             region: "Japan",            zone: "Asia/Tokyo",                      latitude:  35.68, longitude:  139.69),
        TimezoneEntry(id: "osa", city: "Osaka",             region: "Japan",            zone: "Asia/Tokyo",                      latitude:  34.69, longitude:  135.50),
        TimezoneEntry(id: "syd", city: "Sydney",            region: "Australia",        zone: "Australia/Sydney",                latitude: -33.87, longitude:  151.21),
        TimezoneEntry(id: "mel", city: "Melbourne",         region: "Australia",        zone: "Australia/Melbourne",             latitude: -37.81, longitude:  144.96),
        TimezoneEntry(id: "per", city: "Perth",             region: "Australia",        zone: "Australia/Perth",                 latitude: -31.95, longitude:  115.86),
        TimezoneEntry(id: "akl", city: "Auckland",          region: "New Zealand",      zone: "Pacific/Auckland",                latitude: -36.85, longitude:  174.76),
        TimezoneEntry(id: "hnl", city: "Honolulu",          region: "Hawaii, USA",      zone: "Pacific/Honolulu",                latitude:  21.31, longitude: -157.86),
        TimezoneEntry(id: "anc", city: "Anchorage",         region: "Alaska, USA",      zone: "America/Anchorage",               latitude:  61.22, longitude: -149.90),
        TimezoneEntry(id: "rey", city: "Reykjavík",         region: "Iceland",          zone: "Atlantic/Reykjavik",              latitude:  64.15, longitude:  -21.94),
    ]

    static let byId: [String: TimezoneEntry] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
}

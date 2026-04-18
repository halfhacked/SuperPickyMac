import Testing
import Foundation
@testable import SuperPicky

@Suite struct ExifFormattersTests {

    // MARK: - number

    @Test func numberDropsDecimalForWholeValues() {
        #expect(ExifFormatters.number(70) == "70")
        #expect(ExifFormatters.number(0) == "0")
        #expect(ExifFormatters.number(-3) == "-3")
    }

    @Test func numberKeepsOneDecimalForFractions() {
        #expect(ExifFormatters.number(2.8) == "2.8")
        #expect(ExifFormatters.number(6.30) == "6.3")
        #expect(ExifFormatters.number(1.75) == "1.8")  // rounds
    }

    // MARK: - exposure

    @Test func exposureReturnsDashWhenAllNil() {
        #expect(ExifFormatters.exposure(shutterSpeed: nil, aperture: nil, iso: nil) == "—")
    }

    @Test func exposureJoinsShutterApertureWithAt() {
        let s = ExifFormatters.exposure(shutterSpeed: "1/2000", aperture: 6.3, iso: nil)
        #expect(s == "1/2000 at f/6.3")
    }

    @Test func exposureAppendsISOAfterShutterAperture() {
        let s = ExifFormatters.exposure(shutterSpeed: "1/2000", aperture: 6.3, iso: 1600)
        #expect(s == "1/2000 at f/6.3, ISO 1600")
    }

    @Test func exposureWithOnlyShutterReturnsShutter() {
        let s = ExifFormatters.exposure(shutterSpeed: "1s", aperture: nil, iso: nil)
        #expect(s == "1s")
    }

    @Test func exposureWithOnlyApertureReturnsFStop() {
        let s = ExifFormatters.exposure(shutterSpeed: nil, aperture: 2.8, iso: nil)
        #expect(s == "f/2.8")
    }

    @Test func exposureWithOnlyISOReturnsISO() {
        let s = ExifFormatters.exposure(shutterSpeed: nil, aperture: nil, iso: 400)
        #expect(s == "ISO 400")
    }

    @Test func exposureWithShutterAndISOOmitsAt() {
        // No "at" because aperture is missing — just joined with comma.
        let s = ExifFormatters.exposure(shutterSpeed: "1/500", aperture: nil, iso: 800)
        #expect(s == "1/500, ISO 800")
    }

    @Test func exposureWithApertureAndISOOmitsAt() {
        let s = ExifFormatters.exposure(shutterSpeed: nil, aperture: 4, iso: 800)
        #expect(s == "f/4, ISO 800")
    }

    @Test func exposureFormatsWholeApertureWithoutDecimal() {
        let s = ExifFormatters.exposure(shutterSpeed: "1/100", aperture: 4, iso: nil)
        #expect(s == "1/100 at f/4")
    }

    // MARK: - date

    @Test func dateReturnsRawOnUnparseableInput() {
        #expect(ExifFormatters.date("not-a-date", locale: Locale(identifier: "en_US")) == "not-a-date")
        #expect(ExifFormatters.date("", locale: Locale(identifier: "en_US")) == "")
    }

    @Test func dateParsesStandardExifFormatAndFormatsForLocale() {
        // We don't assert exact output (locale format strings vary across
        // macOS versions); only that a parseable date produces output that
        // mentions the year and no longer contains the colon separators.
        let formatted = ExifFormatters.date("2024:07:15 14:30:45",
                                            locale: Locale(identifier: "en_US"))
        #expect(formatted.contains("2024"))
        #expect(!formatted.contains("2024:07"))  // parsed, not echoed
    }

    @Test func dateHonoursLocaleDifferences() {
        // Chinese and English formats differ enough that SOME character
        // varies. Confirming the locale-scope is wired, not the exact glyphs.
        let en = ExifFormatters.date("2024:07:15 14:30:45",
                                     locale: Locale(identifier: "en_US"))
        let zh = ExifFormatters.date("2024:07:15 14:30:45",
                                     locale: Locale(identifier: "zh_CN"))
        #expect(en != zh)
    }

    // MARK: - location

    @Test func locationReturnsNilWhenAllFieldsNil() {
        #expect(ExifFormatters.location(city: nil, state: nil, country: nil) == nil)
    }

    @Test func locationJoinsAvailableFieldsWithCommaSpace() {
        #expect(
            ExifFormatters.location(city: "Seattle", state: "WA", country: "USA")
            == "Seattle, WA, USA"
        )
    }

    @Test func locationSkipsNilFieldsPreservingOrder() {
        #expect(
            ExifFormatters.location(city: "Seattle", state: nil, country: "USA")
            == "Seattle, USA"
        )
        #expect(
            ExifFormatters.location(city: nil, state: "WA", country: nil) == "WA"
        )
    }

    // MARK: - coordinates

    @Test func coordinatesReturnsNilWhenEitherMissing() {
        #expect(ExifFormatters.coordinates(latitude: nil, longitude: 122.0) == nil)
        #expect(ExifFormatters.coordinates(latitude: 47.6, longitude: nil) == nil)
        #expect(ExifFormatters.coordinates(latitude: nil, longitude: nil) == nil)
    }

    @Test func coordinatesFormatsFourDecimalsWithHemisphere() {
        let s = ExifFormatters.coordinates(latitude: 47.6062, longitude: -122.3321)
        #expect(s == "47.6062\u{00B0} N, 122.3321\u{00B0} W")
    }

    @Test func coordinatesSouthernAndEasternHemispheres() {
        let s = ExifFormatters.coordinates(latitude: -33.8688, longitude: 151.2093)
        #expect(s == "33.8688\u{00B0} S, 151.2093\u{00B0} E")
    }

    @Test func coordinatesZeroLatitudeIsNorth() {
        // The boundary: lat == 0 should sort as N (the panel uses >= 0).
        let s = ExifFormatters.coordinates(latitude: 0.0, longitude: 0.0)
        #expect(s == "0.0000\u{00B0} N, 0.0000\u{00B0} E")
    }

    @Test func coordinatesRoundsToFourDecimals() {
        let s = ExifFormatters.coordinates(latitude: 47.606200001, longitude: -122.332199999)
        #expect(s == "47.6062\u{00B0} N, 122.3322\u{00B0} W")
    }
}

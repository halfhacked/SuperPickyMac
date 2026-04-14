import Testing
import Foundation
@testable import SuperPicky

@Suite struct ExifFormattersTests {

    // MARK: - formatNumber

    @Test func formatNumberRendersWholeValueAsInt() {
        #expect(ExifFormatters.formatNumber(400.0) == "400")
        #expect(ExifFormatters.formatNumber(0.0) == "0")
        #expect(ExifFormatters.formatNumber(-3.0) == "-3")
    }

    @Test func formatNumberRendersFractionalWithOneDecimal() {
        #expect(ExifFormatters.formatNumber(6.3) == "6.3")
        #expect(ExifFormatters.formatNumber(1.75) == "1.8")
    }

    // MARK: - formatExposure

    @Test func formatExposureCombinesShutterApertureAndIso() {
        var data = EXIFData()
        data.exposure.shutterSpeed = "1/2000"
        data.exposure.aperture = 6.3
        data.exposure.iso = 1600
        #expect(ExifFormatters.formatExposure(data) == "1/2000 at f/6.3, ISO 1600")
    }

    @Test func formatExposureWithOnlyShutter() {
        var data = EXIFData()
        data.exposure.shutterSpeed = "1/500"
        #expect(ExifFormatters.formatExposure(data) == "1/500")
    }

    @Test func formatExposureWithApertureAndIsoOnly() {
        var data = EXIFData()
        data.exposure.aperture = 2.8
        data.exposure.iso = 100
        #expect(ExifFormatters.formatExposure(data) == "f/2.8, ISO 100")
    }

    @Test func formatExposureFallsBackToEmDashWhenAllNil() {
        let data = EXIFData()
        #expect(ExifFormatters.formatExposure(data) == "—")
    }

    // MARK: - formatDate

    @Test func formatDateConvertsExifFormatToHumanReadable() {
        #expect(ExifFormatters.formatDate("2025:03:15 07:30:22") == "Mar 15, 2025  07:30")
    }

    @Test func formatDateHandlesDateOnly() {
        #expect(ExifFormatters.formatDate("2024:12:01") == "Dec 1, 2024")
    }

    @Test func formatDateReturnsRawWhenUnparseable() {
        #expect(ExifFormatters.formatDate("not a date") == "not a date")
    }

    // MARK: - formatLocation

    @Test func formatLocationJoinsAvailableParts() {
        var data = EXIFData()
        data.location.city = "San Francisco"
        data.location.state = "CA"
        data.location.country = "USA"
        #expect(ExifFormatters.formatLocation(data) == "San Francisco, CA, USA")
    }

    @Test func formatLocationSkipsMissingParts() {
        var data = EXIFData()
        data.location.city = "Tokyo"
        data.location.country = "Japan"
        #expect(ExifFormatters.formatLocation(data) == "Tokyo, Japan")
    }

    @Test func formatLocationReturnsNilWhenAllPartsMissing() {
        let data = EXIFData()
        #expect(ExifFormatters.formatLocation(data) == nil)
    }

    // MARK: - formatCoordinates

    @Test func formatCoordinatesUsesNorthEastForPositive() {
        var data = EXIFData()
        data.location.latitude = 37.7749
        data.location.longitude = 122.4194
        #expect(ExifFormatters.formatCoordinates(data) == "37.7749\u{00B0} N, 122.4194\u{00B0} E")
    }

    @Test func formatCoordinatesUsesSouthWestForNegative() {
        var data = EXIFData()
        data.location.latitude = -33.8688
        data.location.longitude = -151.2093
        #expect(ExifFormatters.formatCoordinates(data) == "33.8688\u{00B0} S, 151.2093\u{00B0} W")
    }

    @Test func formatCoordinatesReturnsNilWithoutBothValues() {
        var data = EXIFData()
        data.location.latitude = 10.0
        #expect(ExifFormatters.formatCoordinates(data) == nil)
    }
}

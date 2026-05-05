import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky
import SuperPickyInference

@Suite struct BurstDetectorGPSTests {

    private func createTestJPEG(
        at path: String,
        exif: [String: Any]? = nil,
        gps: [String: Any]? = nil
    ) {
        let url = URL(fileURLWithPath: path)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var props: [String: Any] = [:]
        if let exif { props[kCGImagePropertyExifDictionary as String] = exif }
        if let gps { props[kCGImagePropertyGPSDictionary as String] = gps }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "BurstGPSTests_\(UUID().uuidString)_\(name)"
    }

    @Test func returnsBothTimestampAndGPS() {
        let path = tempPath("both.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(
            at: path,
            exif: ["DateTimeOriginal": "2024:03:15 14:30:22", "SubSecTimeOriginal": "500"],
            gps: [
                kCGImagePropertyGPSLatitude as String: 47.6062,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.3321,
                kCGImagePropertyGPSLongitudeRef as String: "W",
            ]
        )
        let result = BurstDetector.readPreciseTimestampAndGPS(filePath: path)
        #expect(result.timestamp != nil)
        #expect(result.gps != nil)
        #expect(abs((result.gps?.lat ?? 0) - 47.6062) < 1e-4)
        #expect(abs((result.gps?.lon ?? 0) - (-122.3321)) < 1e-4)
    }

    @Test func timestampOnlyWhenGPSMissing() {
        let path = tempPath("ts-only.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(at: path, exif: ["DateTimeOriginal": "2024:03:15 14:30:22"])
        let result = BurstDetector.readPreciseTimestampAndGPS(filePath: path)
        #expect(result.timestamp != nil)
        #expect(result.gps == nil)
    }

    @Test func allNilForMissingFile() {
        let result = BurstDetector.readPreciseTimestampAndGPS(
            filePath: "/tmp/does-not-exist-\(UUID().uuidString).jpg"
        )
        #expect(result.timestamp == nil)
        #expect(result.gps == nil)
    }

    @Test func southernHemisphereNegatesLatitude() {
        let path = tempPath("south.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(
            at: path,
            gps: [
                kCGImagePropertyGPSLatitude as String: 33.8688,
                kCGImagePropertyGPSLatitudeRef as String: "S",
                kCGImagePropertyGPSLongitude as String: 151.2093,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ]
        )
        let result = BurstDetector.readPreciseTimestampAndGPS(filePath: path)
        #expect(abs((result.gps?.lat ?? 0) - (-33.8688)) < 1e-4)
        #expect(abs((result.gps?.lon ?? 0) - 151.2093) < 1e-4)
    }

    @Test func zeroZeroGPSRejected() {
        let path = tempPath("zero.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(
            at: path,
            gps: [
                kCGImagePropertyGPSLatitude as String: 0.0,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 0.0,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ]
        )
        let result = BurstDetector.readPreciseTimestampAndGPS(filePath: path)
        #expect(result.gps == nil)
    }
}

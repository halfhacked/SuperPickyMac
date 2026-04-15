import Testing
import CoreML
import CoreGraphics
@testable import SuperPickyInference

@Suite("FlightModel")
struct FlightModelTests {

    // MARK: - Preprocessing tests (no model file required)

    @Test("preprocess produces NCHW array of correct shape")
    func preprocessShape() throws {
        let img = makeMonotone(r: 128, g: 128, b: 128, size: 64)
        let array = try FlightModel.preprocess(image: img)
        #expect(array.shape == [1, 3,
                                FlightModel.imageSize as NSNumber,
                                FlightModel.imageSize as NSNumber])
        #expect(array.dataType == .float32)
    }

    @Test("preprocess normalizes white image to correct ImageNet values")
    func preprocessWhiteNormalization() throws {
        // All-white: (1.0 - mean) / std per channel
        let img = makeMonotone(r: 255, g: 255, b: 255, size: FlightModel.imageSize)
        let array = try FlightModel.preprocess(image: img)
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        let size = FlightModel.imageSize
        let expectedR = (1.0 - Float(0.485)) / Float(0.229)  // ≈ 2.249
        let expectedG = (1.0 - Float(0.456)) / Float(0.224)  // ≈ 2.429
        let expectedB = (1.0 - Float(0.406)) / Float(0.225)  // ≈ 2.640
        #expect(abs(ptr[0] - expectedR) < 0.01)                      // first R channel pixel
        #expect(abs(ptr[size * size] - expectedG) < 0.01)            // first G channel pixel
        #expect(abs(ptr[2 * size * size] - expectedB) < 0.01)        // first B channel pixel
    }

    @Test("preprocess normalizes black image to negative values")
    func preprocessBlackNormalization() throws {
        let img = makeMonotone(r: 0, g: 0, b: 0, size: FlightModel.imageSize)
        let array = try FlightModel.preprocess(image: img)
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        // (0.0 - 0.485) / 0.229 ≈ -2.118
        #expect(ptr[0] < -2.0)
    }

    @Test("preprocess allocates fresh buffer each call (no shared mutable state)")
    func preprocessFreshBuffer() throws {
        let img = makeMonotone(r: 128, g: 100, b: 200, size: 64)
        let a = try FlightModel.preprocess(image: img)
        let b = try FlightModel.preprocess(image: img)
        #expect(a.dataPointer != b.dataPointer)
    }

    // MARK: - Helpers

    private func makeMonotone(r: UInt8, g: UInt8, b: UInt8, size: Int) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = r; pixels[i+1] = g; pixels[i+2] = b; pixels[i+3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: size, height: size,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

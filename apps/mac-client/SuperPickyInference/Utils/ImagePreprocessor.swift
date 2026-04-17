// ImagePreprocessor.swift
//
// Shared, Accelerate-backed pixel → MLMultiArray preprocessing for every
// CoreML wrapper in the pipeline. Previously each model wrapper ran its
// own scalar Swift loop over all pixels; that loop is ~4–10 ms per photo
// per model and was the biggest contributor of CPU time between ANE
// submissions. Vectorizing it with `vDSP_vfltu8` + `vDSP_vsmsa` is ~10×
// faster and, because it's bit-equivalent, requires no model re-export.

import Accelerate
import CoreGraphics
import CoreML
import Foundation
import simd

public enum ImagePreprocessor {

    /// Render `image` to `size × size` RGBA8888, then pack into a
    /// `[1, 3, size, size]` NCHW float32 MLMultiArray, normalized as
    /// `(pixel/255 - mean) / std` per channel.
    ///
    /// Pass `mean=(0,0,0)` and `std=(1,1,1)` for models that apply their
    /// own normalization internally (e.g. CFANet/TOPIQ aesthetics).
    public static func normalizedNCHW(
        image: CGImage,
        size: Int,
        mean: SIMD3<Float> = InferenceConstants.imageNetMean,
        std: SIMD3<Float> = InferenceConstants.imageNetStd,
        interpolation: CGInterpolationQuality = .high
    ) throws -> MLMultiArray {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PreprocessError.contextCreationFailed }
        ctx.interpolationQuality = interpolation
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        return try normalizedNCHW(
            rgbaPixels: &pixels, size: size, mean: mean, std: std
        )
    }

    /// Variant that consumes a caller-owned `size*size*4` RGBA8888 buffer.
    /// Useful when the buffer was already rendered for another purpose
    /// (e.g. the head-sharpness mask) and we want to avoid re-rendering.
    public static func normalizedNCHW(
        rgbaPixels: UnsafeMutablePointer<UInt8>,
        size: Int,
        mean: SIMD3<Float>,
        std: SIMD3<Float>
    ) throws -> MLMultiArray {
        let n = size * size
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )
        let base = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * n)

        // For each of R, G, B: strided uint8 → float32, then fused
        // scale-multiply-subtract-add (x * scale + bias) where
        //   scale = 1 / (255 * std_c)
        //   bias  = -mean_c / std_c
        // gives the same `(x/255 - mean) / std` the scalar code produced.
        for c in 0..<3 {
            let plane = base + c * n
            let meanC = (c == 0 ? mean.x : (c == 1 ? mean.y : mean.z))
            let stdC  = (c == 0 ? std.x  : (c == 1 ? std.y  : std.z))

            vDSP_vfltu8(rgbaPixels.advanced(by: c), 4, plane, 1, vDSP_Length(n))

            var scale: Float = 1.0 / (255.0 * stdC)
            var bias:  Float = -meanC / stdC
            vDSP_vsmsa(plane, 1, &scale, &bias, plane, 1, vDSP_Length(n))
        }
        return array
    }

    /// Return a new `[1, 3, size, size]` NCHW array that is `src`
    /// horizontally flipped (reversed along the W axis). Used for OSEA
    /// TTA — the original path was `CGContext flip → preprocess(flipped)`
    /// which paid for a second image render + a second normalize pass;
    /// reversing the already-preprocessed tensor costs a `memcpy` plus
    /// `3 × size` `vDSP_vrvrs` calls (~150 µs for size=224).
    public static func horizontalFlipNCHW(_ src: MLMultiArray) throws -> MLMultiArray {
        guard src.dataType == .float32, src.shape.count == 4 else {
            throw PreprocessError.unsupportedShape
        }
        let n = src.shape[0].intValue
        let c = src.shape[1].intValue
        let h = src.shape[2].intValue
        let w = src.shape[3].intValue
        let total = n * c * h * w

        let dst = try MLMultiArray(shape: src.shape, dataType: .float32)
        let srcPtr = src.dataPointer.bindMemory(to: Float.self, capacity: total)
        let dstPtr = dst.dataPointer.bindMemory(to: Float.self, capacity: total)

        memcpy(dstPtr, srcPtr, total * MemoryLayout<Float>.size)
        let wLen = vDSP_Length(w)
        for idx in 0..<(n * c * h) {
            vDSP_vrvrs(dstPtr + idx * w, 1, wLen)
        }
        return dst
    }
}

public enum PreprocessError: Error {
    case contextCreationFailed
    case unsupportedShape
}

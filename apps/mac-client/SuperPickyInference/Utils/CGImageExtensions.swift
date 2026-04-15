// CGImageExtensions.swift
//
// Shared image utilities used by all CoreML model wrappers.
// Keep this file free of model-specific logic.

import CoreGraphics

extension CGImage {
    /// Resize the image to the given size using high-quality interpolation.
    /// Returns nil only if the CGContext cannot be created.
    func resized(to size: CGSize) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

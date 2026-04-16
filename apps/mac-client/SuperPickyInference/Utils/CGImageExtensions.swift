// CGImageExtensions.swift
//
// Shared image utilities used by all CoreML model wrappers.
// Keep this file free of model-specific logic.

import CoreGraphics

public extension CGImage {
    /// Smart square bird crop matching preen/SuperPicky's
    /// `YOLOBirdDetector.detect_and_crop_bird` behavior:
    /// 1. Expand the bbox to a square sized `maxSide × (1 + paddingRatio)`,
    ///    centered on the bbox center.
    /// 2. Clamp the square to image bounds.
    /// 3. If the clamped crop is not square (bird was near an edge),
    ///    letterbox it with black fill to a square canvas.
    ///
    /// This matches what the flight / keypoint / OSEA classifiers were
    /// trained on — a square crop with ~15 % context around the bird.
    /// Feeding a raw rectangular YOLO crop and stretching it to 384×384
    /// distorts the bird's aspect ratio and causes false positives.
    ///
    /// - Parameters:
    ///   - bbox: Bird bbox in normalized [0, 1] coordinates (top-left origin).
    ///   - paddingRatio: Extra context around the bbox, as a fraction of
    ///     the max side. Default 0.15 matches preen.
    /// - Returns: A square CGImage, or nil if the input bbox is degenerate.
    func smartSquareBirdCrop(bbox: CGRect, paddingRatio: CGFloat = 0.15) -> CGImage? {
        let imgW = self.width
        let imgH = self.height
        guard imgW > 0, imgH > 0 else { return nil }

        // Pixel-space bbox (integer, top-left origin).
        let px1 = Int((bbox.origin.x * CGFloat(imgW)).rounded(.down))
        let py1 = Int((bbox.origin.y * CGFloat(imgH)).rounded(.down))
        let px2 = Int(((bbox.origin.x + bbox.size.width) * CGFloat(imgW)).rounded(.up))
        let py2 = Int(((bbox.origin.y + bbox.size.height) * CGFloat(imgH)).rounded(.up))

        let bboxW = px2 - px1
        let bboxH = py2 - py1
        guard bboxW > 0, bboxH > 0 else { return nil }

        // Smart square expansion (matches Python: target = max_side * (1 + padding))
        let maxSide = max(bboxW, bboxH)
        let targetSide = Int(Double(maxSide) * (1.0 + Double(paddingRatio)))

        let cx = (px1 + px2) / 2
        let cy = (py1 + py2) / 2
        let half = targetSide / 2

        let sqX1 = cx - half
        let sqY1 = cy - half
        let sqX2 = cx + half
        let sqY2 = cy + half

        // Clamp to image bounds.
        let cropX1 = max(0, sqX1)
        let cropY1 = max(0, sqY1)
        let cropX2 = min(imgW, sqX2)
        let cropY2 = min(imgH, sqY2)
        let cropW = cropX2 - cropX1
        let cropH = cropY2 - cropY1
        guard cropW > 0, cropH > 0 else { return nil }

        guard let cropped = self.cropping(to: CGRect(x: cropX1, y: cropY1,
                                                      width: cropW, height: cropH)) else {
            return nil
        }

        // Already square? Return as-is.
        if cropW == cropH { return cropped }

        // Letterbox: center the clamped rectangle in a square canvas
        // of size max(cropW, cropH) with black fill (matches Python fill_color=(0,0,0)).
        let sqSize = max(cropW, cropH)
        guard let ctx = CGContext(
            data: nil,
            width: sqSize, height: sqSize,
            bitsPerComponent: 8,
            bytesPerRow: sqSize * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: sqSize, height: sqSize))

        // CGContext origin is bottom-left, so `pasteY` is offset from the bottom.
        // Center both axes the same way: (canvas - content) / 2.
        let pasteX = (sqSize - cropW) / 2
        let pasteY = (sqSize - cropH) / 2
        ctx.interpolationQuality = .none  // no scaling — just a copy into the black canvas
        ctx.draw(cropped, in: CGRect(x: pasteX, y: pasteY, width: cropW, height: cropH))
        return ctx.makeImage()
    }

    /// Resize the image to the given size.
    /// - Parameter quality: CG interpolation quality. For CoreML inputs that
    ///   were trained with PyTorch `transforms.Resize(..., interpolation=BILINEAR)`,
    ///   pass `.low` (which maps to bilinear) so the runtime interpolation
    ///   matches training distribution. `.high` is Lanczos, which produces
    ///   visibly sharper results and can shift a binary classifier's decision
    ///   near threshold.
    /// - Returns: Resized CGImage, or nil if the CGContext cannot be created.
    func resized(to size: CGSize, quality: CGInterpolationQuality = .high) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = quality
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

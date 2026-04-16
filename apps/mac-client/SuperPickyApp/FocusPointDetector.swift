import Foundation
import CoreGraphics
import ImageIO

/// Detects focus point from RAW EXIF and computes sharpness/aesthetics weights
/// based on where the focus falls relative to the bird.
///
/// Weight tiers (matches superpicky):
/// - head:     (1.1, 1.0)  Focus inside head circle
/// - seg:      (0.9, 1.0)  Focus inside segmentation mask but outside head
/// - bbox:     (0.8, 0.9)  Focus inside bbox but outside seg/head
/// - missed:   (0.5, 0.8)  Focus outside bbox entirely
/// - unfocused: (0.8, 0.9) AF attempted but didn't lock
/// - unknown:  (1.0, 1.0)  No AF data available
struct FocusPointDetector {
    struct FocusWeights: Equatable {
        let sharpness: Float
        let aesthetics: Float

        static let headFocus = FocusWeights(sharpness: 1.1, aesthetics: 1.0)
        static let segFocus = FocusWeights(sharpness: 0.9, aesthetics: 1.0)
        static let bboxFocus = FocusWeights(sharpness: 0.8, aesthetics: 0.9)
        static let missedFocus = FocusWeights(sharpness: 0.5, aesthetics: 0.8)
        static let unfocused = FocusWeights(sharpness: 0.8, aesthetics: 0.9)
        static let unknown = FocusWeights(sharpness: 1.0, aesthetics: 1.0)
    }

    /// EXIF-extracted focus point result.
    struct FocusPointResult {
        let x: Float           // Normalized 0-1
        let y: Float           // Normalized 0-1
        let isFocused: Bool    // Whether AF locked
    }

    // MARK: - Primary API (file-based, reads EXIF)

    /// Compute focus weights for a photo by reading EXIF from the file.
    /// - Parameters:
    ///   - filePath: Path to the RAW/image file
    ///   - birdBbox: Normalized bird bounding box (x, y, w, h) in 0-1 space
    ///   - eyeCenter: Normalized (x, y) of the best eye in bird-crop space (0-1 relative to crop)
    ///   - headRadiusFraction: Approximate head radius as fraction of crop size
    ///   - segMask: Optional YOLO segmentation mask (flattened uint8 array)
    ///   - maskWidth: Width of the seg mask in pixels
    ///   - maskHeight: Height of the seg mask in pixels
    static func computeWeights(
        filePath: String,
        birdBbox: CGRect,
        eyeCenter: (x: Float, y: Float)?,
        headRadiusFraction: Float,
        segMask: Data? = nil,
        maskWidth: Int = 0,
        maskHeight: Int = 0
    ) -> FocusWeights {
        guard let focusResult = readFocusPoint(filePath: filePath) else {
            return .unknown
        }

        return computeWeights(
            focusPoint: (x: focusResult.x, y: focusResult.y),
            isFocused: focusResult.isFocused,
            birdBbox: birdBbox,
            eyeCenter: eyeCenter,
            headRadiusFraction: headRadiusFraction,
            segMask: segMask,
            maskWidth: maskWidth,
            maskHeight: maskHeight
        )
    }

    /// Variant that consumes a pre-loaded `CGImageSource` properties dict,
    /// so the pipeline can open the file once per photo and fan the dict
    /// out to every consumer (EXIFReader, this detector, …).
    static func computeWeights(
        properties: [String: Any],
        birdBbox: CGRect,
        eyeCenter: (x: Float, y: Float)?,
        headRadiusFraction: Float,
        segMask: Data? = nil,
        maskWidth: Int = 0,
        maskHeight: Int = 0
    ) -> FocusWeights {
        guard let focusResult = readFocusPoint(properties: properties) else {
            return .unknown
        }
        return computeWeights(
            focusPoint: (x: focusResult.x, y: focusResult.y),
            isFocused: focusResult.isFocused,
            birdBbox: birdBbox,
            eyeCenter: eyeCenter,
            headRadiusFraction: headRadiusFraction,
            segMask: segMask,
            maskWidth: maskWidth,
            maskHeight: maskHeight
        )
    }

    // MARK: - Pure computation API (testable without files)

    /// Compute focus weights from pre-extracted focus point and bird geometry.
    /// This is the testable core — no file I/O.
    static func computeWeights(
        focusPoint: (x: Float, y: Float)?,
        isFocused: Bool,
        birdBbox: CGRect,
        eyeCenter: (x: Float, y: Float)?,
        headRadiusFraction: Float,
        segMask: Data?,
        maskWidth: Int,
        maskHeight: Int
    ) -> FocusWeights {
        guard let fp = focusPoint else {
            return .unknown
        }

        // AF attempted but didn't lock
        guard isFocused else {
            return .unfocused
        }

        let fx = CGFloat(fp.x)
        let fy = CGFloat(fp.y)

        // Layer 4: Focus outside bird bbox
        guard birdBbox.contains(CGPoint(x: fx, y: fy)) else {
            return .missedFocus
        }

        // Layer 1: Focus inside head circle
        if let eye = eyeCenter {
            let eyeImgX = birdBbox.origin.x + CGFloat(eye.x) * birdBbox.width
            let eyeImgY = birdBbox.origin.y + CGFloat(eye.y) * birdBbox.height
            let headR = CGFloat(headRadiusFraction) * max(birdBbox.width, birdBbox.height)

            let dx = fx - eyeImgX
            let dy = fy - eyeImgY
            if dx * dx + dy * dy <= headR * headR {
                return .headFocus
            }
        }

        // Layer 2: Focus inside segmentation mask
        if let mask = segMask, !mask.isEmpty, maskWidth > 0, maskHeight > 0 {
            let maskX = Int(fp.x * Float(maskWidth))
            let maskY = Int(fp.y * Float(maskHeight))
            let clampedX = min(max(maskX, 0), maskWidth - 1)
            let clampedY = min(max(maskY, 0), maskHeight - 1)
            let idx = clampedY * maskWidth + clampedX
            if idx < mask.count && mask[idx] > 0 {
                return .segFocus
            }
        }

        // Layer 3: Focus inside bbox (but outside head and seg)
        return .bboxFocus
    }

    // MARK: - EXIF reading

    /// Read focus point from image EXIF.
    /// Supports: Sony (SubjectArea), Nikon (MakerNote AF), generic SubjectArea.
    /// Returns nil when no AF data is available.
    static func readFocusPoint(filePath: String) -> FocusPointResult? {
        guard let props = ImageProperties.load(filePath: filePath) else { return nil }
        return readFocusPoint(properties: props)
    }

    /// Parse the focus point from a pre-loaded properties dict.
    static func readFocusPoint(properties props: [String: Any]) -> FocusPointResult? {
        let pixelWidth = (props["PixelWidth"] as? Int) ?? 0
        let pixelHeight = (props["PixelHeight"] as? Int) ?? 0

        // Get orientation for rotation correction
        let tiffDict = props["{TIFF}"] as? [String: Any]
        let orientation = (tiffDict?["Orientation"] as? Int) ?? 1

        // Try MakerNote (brand-specific AF data)
        if let makerNote = props["{MakerNote}"] as? [String: Any] {
            // Nikon: AFAreaXPosition/AFAreaYPosition + AFImageWidth/AFImageHeight
            if let afX = makerNote["AFAreaXPosition"] as? Int,
               let afY = makerNote["AFAreaYPosition"] as? Int,
               let afW = makerNote["AFImageWidth"] as? Int,
               let afH = makerNote["AFImageHeight"] as? Int,
               afW > 0, afH > 0 {
                var normX = Float(afX) / Float(afW)
                var normY = Float(afY) / Float(afH)
                (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)
                let focusResult = makerNote["FocusResult"] as? Int
                return FocusPointResult(x: normX, y: normY, isFocused: focusResult != 0)
            }
        }

        // Try EXIF SubjectArea (standard field: [x, y] or [x, y, d] or [x, y, w, h])
        if let exif = props["{Exif}"] as? [String: Any],
           let subjectArea = exif["SubjectArea"] as? [NSNumber], subjectArea.count >= 2 {
            let values = subjectArea.map { $0.intValue }
            if let parsed = parseSubjectArea(subjectArea: values, imageWidth: pixelWidth, imageHeight: pixelHeight) {
                var normX = parsed.x
                var normY = parsed.y
                (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)
                // SubjectArea presence implies AF was used; assume focused unless other indicators
                return FocusPointResult(x: normX, y: normY, isFocused: true)
            }
        }

        return nil  // No focus data → caller gets .unknown
    }

    // MARK: - SubjectArea parsing (exposed for testing)

    /// Parse EXIF SubjectArea values into normalized coordinates.
    /// SubjectArea can be [x, y], [x, y, diameter], or [x, y, w, h] in pixel coords.
    static func parseSubjectArea(subjectArea: [Int], imageWidth: Int, imageHeight: Int) -> (x: Float, y: Float)? {
        guard subjectArea.count >= 2, imageWidth > 0, imageHeight > 0 else {
            return nil
        }
        let x = Float(subjectArea[0]) / Float(imageWidth)
        let y = Float(subjectArea[1]) / Float(imageHeight)
        return (x: x, y: y)
    }

    // MARK: - Orientation correction (exposed for testing)

    /// Apply EXIF orientation correction to normalized coordinates.
    /// Matches superpicky's `_apply_orientation_correction`.
    static func applyOrientationCorrection(x: Float, y: Float, orientation: Int) -> (x: Float, y: Float) {
        switch orientation {
        case 6:
            // Rotate 90° CW: (x, y) → (y, 1-x)
            return (x: y, y: 1.0 - x)
        case 8:
            // Rotate 270° CW: (x, y) → (1-y, x)
            return (x: 1.0 - y, y: x)
        default:
            return (x: x, y: y)
        }
    }
}

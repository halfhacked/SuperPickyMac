import Foundation
import CoreGraphics
import ImageIO
import SuperPickyInference

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
    /// Brand-dispatches by `{TIFF}.Make`:
    /// - **Sony**: parses MakerNote `FocusLocation` ("imgW imgH x y") and
    ///   `FocusFrameSize` for the focus-validity flag.
    /// - **Nikon**: parses MakerNote `AFAreaXPosition` / `AFImageWidth`.
    /// - **Other / unknown**: falls through to standard EXIF `SubjectArea`.
    /// Returns nil when no AF data is available.
    static func readFocusPoint(filePath: String) -> FocusPointResult? {
        guard let props = ImageProperties.load(filePath: filePath) else { return nil }
        return readFocusPoint(properties: props)
    }

    /// Parse the focus point from a pre-loaded properties dict.
    static func readFocusPoint(properties props: [String: Any]) -> FocusPointResult? {
        let pixelWidth = (props["PixelWidth"] as? Int) ?? 0
        let pixelHeight = (props["PixelHeight"] as? Int) ?? 0

        let tiffDict = props["{TIFF}"] as? [String: Any]
        let orientation = (tiffDict?["Orientation"] as? Int) ?? 1
        let make = ((tiffDict?["Make"] as? String) ?? "").uppercased()
        let model = (tiffDict?["Model"] as? String) ?? ""

        let makerNote = props["{MakerNote}"] as? [String: Any]

        // Brand-specific MakerNote parsers (matches superpicky's
        // _detect_<brand> dispatch in focus_point_detector.py).
        if make.contains("SONY"), let mn = makerNote,
           let result = parseSonyFocusPoint(makerNote: mn, orientation: orientation) {
            return result
        }
        if make.contains("CANON"), let mn = makerNote,
           let result = parseCanonFocusPoint(makerNote: mn, model: model, orientation: orientation) {
            return result
        }
        if (make.contains("OLYMPUS") || make.contains("OM DIGITAL")), let mn = makerNote,
           let result = parseOlympusFocusPoint(makerNote: mn,
                                                imageWidth: pixelWidth, imageHeight: pixelHeight,
                                                orientation: orientation) {
            return result
        }
        if make.contains("FUJIFILM"), let mn = makerNote,
           let result = parseFujifilmFocusPoint(makerNote: mn,
                                                 imageWidth: pixelWidth, imageHeight: pixelHeight,
                                                 orientation: orientation) {
            return result
        }
        if make.contains("PANASONIC"), let mn = makerNote,
           let result = parsePanasonicFocusPoint(makerNote: mn, orientation: orientation) {
            return result
        }
        if make.contains("NIKON"), let mn = makerNote,
           let result = parseNikonFocusPoint(makerNote: mn, orientation: orientation) {
            return result
        }
        // Generic Nikon match for files where Make is missing but the
        // MakerNote layout is Nikon's — covers older NEFs.
        if let mn = makerNote,
           let result = parseNikonFocusPoint(makerNote: mn, orientation: orientation) {
            return result
        }

        // Standard EXIF SubjectArea fallback ([x, y] / [x, y, d] / [x, y, w, h]).
        if let exif = props["{Exif}"] as? [String: Any],
           let subjectArea = exif["SubjectArea"] as? [NSNumber], subjectArea.count >= 2 {
            let values = subjectArea.map { $0.intValue }
            if let parsed = parseSubjectArea(subjectArea: values, imageWidth: pixelWidth, imageHeight: pixelHeight) {
                var normX = parsed.x
                var normY = parsed.y
                (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)
                return FocusPointResult(x: normX, y: normY, isFocused: true)
            }
        }

        return nil
    }

    // MARK: - Sony FocusLocation parsing (exposed for testing)

    /// Parse a Sony MakerNote dict into a focus point.
    ///
    /// Sony A1/A7Rx/A9 expose:
    /// - `FocusLocation` — `"imgW imgH focusX focusY"` (4 ints, image-pixel coords)
    /// - `FocusFrameSize` — `"width height validity"` (3 ints; validity 0 → AF didn't lock)
    /// - `FocusMode` — `"1"` or string containing `MF`/`MANUAL` → manual focus, no AF data
    ///
    /// Both string and array bridgings are accepted because ImageIO and
    /// exiftool surface these tags in different shapes depending on macOS version.
    /// Mirrors superpicky's `_detect_sony` in
    /// `core/focus_point_detector.py:237-305`.
    static func parseSonyFocusPoint(
        makerNote: [String: Any],
        orientation: Int
    ) -> FocusPointResult? {
        // Manual focus → no AF data
        if let mode = makerNote["FocusMode"] {
            let modeStr = String(describing: mode).uppercased()
            if modeStr == "1" || modeStr.contains("MF") || modeStr.contains("MANUAL") {
                return nil
            }
        }

        guard let parts = sonyIntArray(makerNote["FocusLocation"]),
              parts.count >= 4 else {
            return nil
        }
        let imgW = parts[0], imgH = parts[1]
        let rawX = parts[2], rawY = parts[3]
        guard imgW > 0, imgH > 0 else { return nil }

        var normX = Float(rawX) / Float(imgW)
        var normY = Float(rawY) / Float(imgH)
        (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)

        // FocusFrameSize[2] != 0 → AF locked. Default focused=true when the
        // tag is absent (Python's "no flag → conservative assume focused").
        var isFocused = true
        if let frame = sonyIntArray(makerNote["FocusFrameSize"]), frame.count >= 3 {
            isFocused = frame[2] != 0
        }
        return FocusPointResult(x: normX, y: normY, isFocused: isFocused)
    }

    /// Tolerant int-array bridging for Sony MakerNote tags, which surface
    /// as either a space-separated string (exiftool form) or an `[NSNumber]`
    /// (ImageIO form depending on macOS version).
    private static func sonyIntArray(_ value: Any?) -> [Int]? {
        if let arr = value as? [NSNumber] { return arr.map { $0.intValue } }
        if let str = value as? String {
            let parts = str.split(whereSeparator: { $0.isWhitespace })
            let ints = parts.compactMap { Int($0) }
            return ints.isEmpty ? nil : ints
        }
        return nil
    }

    // MARK: - Olympus AF parsing (exposed for testing)

    /// Parse an Olympus / OM System MakerNote dict into a focus point.
    ///
    /// Olympus exposes the AF point in two forms; we prefer the first:
    /// 1. `AFPointSelected` — normalized `"x y"` (0.0-1.0). Sometimes wrapped
    ///    as `"(50%,50%)"` on certain bodies.
    /// 2. `AFFocusArea` (pixel `"x y w h"`) + `AFFrameSize` (`"w h"`).
    ///
    /// Mirrors superpicky's `_detect_olympus`
    /// (`core/focus_point_detector.py:423-534`).
    static func parseOlympusFocusPoint(
        makerNote: [String: Any],
        imageWidth: Int,
        imageHeight: Int,
        orientation: Int
    ) -> FocusPointResult? {
        if let mode = makerNote["FocusMode"] {
            let modeStr = String(describing: mode).uppercased()
            if modeStr.contains("MF") || modeStr.contains("MANUAL") { return nil }
        }

        // Path 1: AFPointSelected normalized
        if let raw = makerNote["AFPointSelected"] {
            let str = String(describing: raw)
            if !str.isEmpty, str != "0 0" {
                if str.contains("%") {
                    // "(50%,50%)"
                    let digits = str.split(whereSeparator: { !$0.isNumber })
                                    .compactMap { Int($0) }
                    if digits.count >= 2 {
                        var nx = Float(digits[0]) / 100
                        var ny = Float(digits[1]) / 100
                        (nx, ny) = applyOrientationCorrection(x: nx, y: ny, orientation: orientation)
                        return FocusPointResult(x: nx, y: ny, isFocused: true)
                    }
                } else {
                    let parts = str.split(whereSeparator: { $0.isWhitespace })
                                   .compactMap { Float($0) }
                    if parts.count >= 2 {
                        var nx = parts[0], ny = parts[1]
                        (nx, ny) = applyOrientationCorrection(x: nx, y: ny, orientation: orientation)
                        return FocusPointResult(x: nx, y: ny, isFocused: true)
                    }
                }
            }
        }

        // Path 2: AFFocusArea pixel coords + AFFrameSize
        if let area = sonyIntArray(makerNote["AFFocusArea"]),
           let frame = sonyIntArray(makerNote["AFFrameSize"]),
           area.count >= 4, frame.count >= 2 {
            let (frameW, frameH) = (frame[0], frame[1])
            guard frameW > 0, frameH > 0 else { return nil }
            let centerX = area[0] + area[2] / 2
            let centerY = area[1] + area[3] / 2
            var nx = Float(centerX) / Float(frameW)
            var ny = Float(centerY) / Float(frameH)
            (nx, ny) = applyOrientationCorrection(x: nx, y: ny, orientation: orientation)
            return FocusPointResult(x: nx, y: ny, isFocused: true)
        }

        _ = (imageWidth, imageHeight)  // reserved for future raw-px result
        return nil
    }

    // MARK: - Fujifilm AF parsing (exposed for testing)

    /// Parse a Fujifilm X / GFX MakerNote dict into a focus point.
    ///
    /// Fujifilm stores `FocusPixel` as `"x y"` in **embedded-JPEG-preview**
    /// pixel coordinates (not the full RAW frame). The reference frame is
    /// `ExifImageWidth` / `ExifImageHeight` from the EXIF dict — mirrors
    /// the V3.9 fix in `superpicky/core/focus_point_detector.py:566-580`
    /// where using `RawImageCroppedSize` instead caused a ~0.29 mis-norm.
    static func parseFujifilmFocusPoint(
        makerNote: [String: Any],
        imageWidth: Int,
        imageHeight: Int,
        orientation: Int
    ) -> FocusPointResult? {
        if let mode = makerNote["FocusMode"] {
            let modeStr = String(describing: mode).uppercased()
            if modeStr.contains("MF") || modeStr.contains("MANUAL") { return nil }
        }
        guard imageWidth > 0, imageHeight > 0,
              let parts = sonyIntArray(makerNote["FocusPixel"]),
              parts.count >= 2 else {
            return nil
        }
        let rawX = parts[0], rawY = parts[1]
        var nx = Float(rawX) / Float(imageWidth)
        var ny = Float(rawY) / Float(imageHeight)
        (nx, ny) = applyOrientationCorrection(x: nx, y: ny, orientation: orientation)
        return FocusPointResult(x: nx, y: ny, isFocused: true)
    }

    // MARK: - Panasonic AF parsing (exposed for testing)

    /// Parse a Panasonic LUMIX S / G MakerNote dict into a focus point.
    /// `AFPointPosition` is normalized `"x y"`; the value `4.194e+006`
    /// is Panasonic's "no AF point" sentinel and must be rejected.
    static func parsePanasonicFocusPoint(
        makerNote: [String: Any],
        orientation: Int
    ) -> FocusPointResult? {
        if let mode = makerNote["FocusMode"] {
            let modeStr = String(describing: mode).uppercased()
            if modeStr.contains("MF") || modeStr.contains("MANUAL") { return nil }
        }
        guard let raw = makerNote["AFPointPosition"] else { return nil }
        let str = String(describing: raw)
        if str.isEmpty || str.contains("4.194e") { return nil }
        let parts = str.split(whereSeparator: { $0.isWhitespace })
                       .compactMap { Float($0) }
        guard parts.count >= 2 else { return nil }
        var nx = parts[0], ny = parts[1]
        (nx, ny) = applyOrientationCorrection(x: nx, y: ny, orientation: orientation)
        return FocusPointResult(x: nx, y: ny, isFocused: true)
    }

    // MARK: - Canon AF parsing (exposed for testing)

    /// Parse a Canon MakerNote dict into a focus point.
    ///
    /// Canon stores AF point positions as **offsets from image center**:
    /// - `AFAreaXPositions` / `AFAreaYPositions` — space-separated ints,
    ///   one entry per AF point.
    /// - `AFImageWidth` / `AFImageHeight` — reference frame for the offsets.
    /// - `AFPointsInFocus` — bitmask ("1 0 0 0 …") or comma-separated
    ///   indices ("0,1") indicating which AF points actually locked.
    /// - Y axis is inverted on EOS bodies (DSLR/mirrorless) and normal on
    ///   compact bodies (PowerShot/IXUS/ELPH); detected from the `Model` tag.
    /// - `FocusMode` containing "MF"/"MANUAL" → manual focus, no AF data.
    ///
    /// Mirrors superpicky's `_detect_canon` in
    /// `core/focus_point_detector.py:307-421`.
    static func parseCanonFocusPoint(
        makerNote: [String: Any],
        model: String,
        orientation: Int
    ) -> FocusPointResult? {
        if let mode = makerNote["FocusMode"] {
            let modeStr = String(describing: mode).uppercased()
            if modeStr.contains("MF") || modeStr.contains("MANUAL") { return nil }
        }

        guard let imgW = (makerNote["AFImageWidth"] as? Int)
                ?? (makerNote["ExifImageWidth"] as? Int),
              let imgH = (makerNote["AFImageHeight"] as? Int)
                ?? (makerNote["ExifImageHeight"] as? Int),
              imgW > 0, imgH > 0 else {
            return nil
        }

        guard let xList = sonyIntArray(makerNote["AFAreaXPositions"]),
              let yList = sonyIntArray(makerNote["AFAreaYPositions"]),
              !xList.isEmpty, !yList.isEmpty else {
            return nil
        }

        // Resolve which AF point locked. Two encodings:
        //   "1 0 0 0 …"  → bitmask, indices where value==1 are in focus
        //   "0,1"        → comma-separated index list
        var focusIndices: [Int] = []
        if let raw = makerNote["AFPointsInFocus"] {
            let str = String(describing: raw).trimmingCharacters(in: .whitespaces)
            if !str.isEmpty {
                if str.contains(",") {
                    focusIndices = str.split(separator: ",")
                        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                } else {
                    let parts = str.split(whereSeparator: { $0.isWhitespace })
                    focusIndices = parts.enumerated()
                        .filter { $1 == "1" || $1 == "1.0" }
                        .map { $0.offset }
                }
            }
        }
        let idx = (focusIndices.first.flatMap { $0 < xList.count ? $0 : nil }) ?? 0
        guard idx < yList.count else { return nil }

        // Y axis: EOS bodies invert, compact bodies don't.
        let modelUpper = model.uppercased()
        let isCompact = modelUpper.contains("POWERSHOT")
            || modelUpper.contains("IXUS")
            || modelUpper.contains("ELPH")
        let yDirection = isCompact ? 1 : -1

        let rawX = imgW / 2 + xList[idx]
        let rawY = imgH / 2 + yList[idx] * yDirection

        var normX = Float(rawX) / Float(imgW)
        var normY = Float(rawY) / Float(imgH)
        (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)

        // Locked iff at least one AFPointsInFocus index resolved.
        let isFocused = !focusIndices.isEmpty
        return FocusPointResult(x: normX, y: normY, isFocused: isFocused)
    }

    // MARK: - Nikon AF parsing (exposed for testing)

    /// Parse a Nikon MakerNote dict into a focus point.
    /// Nikon stores `AFAreaXPosition`/`AFAreaYPosition` against
    /// `AFImageWidth`/`AFImageHeight`; `FocusResult != 0` indicates lock.
    static func parseNikonFocusPoint(
        makerNote: [String: Any],
        orientation: Int
    ) -> FocusPointResult? {
        guard let afX = makerNote["AFAreaXPosition"] as? Int,
              let afY = makerNote["AFAreaYPosition"] as? Int,
              let afW = makerNote["AFImageWidth"] as? Int,
              let afH = makerNote["AFImageHeight"] as? Int,
              afW > 0, afH > 0 else {
            return nil
        }
        var normX = Float(afX) / Float(afW)
        var normY = Float(afY) / Float(afH)
        (normX, normY) = applyOrientationCorrection(x: normX, y: normY, orientation: orientation)
        let focusResult = makerNote["FocusResult"] as? Int
        return FocusPointResult(x: normX, y: normY, isFocused: focusResult != 0)
    }

    // MARK: - Head radius (exposed for testing)

    /// Compute the head-circle radius (as a fraction of `max(bbox.w, bbox.h)`)
    /// for the .headFocus tier, mirroring HeadSharpness's radius logic:
    ///
    /// - `beak visible` → eye-beak distance × 1.2 (in bird-crop coordinates,
    ///   used as a bbox-relative fraction by the existing `computeWeights`
    ///   math).
    /// - `beak hidden`  → 0.15, the no-beak fallback constant.
    ///
    /// Mirrors superpicky's `head_radius_val` derivation in
    /// `keypoint_detector.py:282-290`.
    static func headRadiusFraction(
        beakVisibility: Float,
        eye: (x: Float, y: Float),
        beak: (x: Float, y: Float),
        visibilityThreshold: Float = InferenceConstants.keypointVisibilityThreshold,
        radiusMultiplier: Float = 1.2,
        noBeakRatio: Float = 0.15
    ) -> Float {
        if beakVisibility >= visibilityThreshold {
            return hypot(eye.x - beak.x, eye.y - beak.y) * radiusMultiplier
        }
        return noBeakRatio
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

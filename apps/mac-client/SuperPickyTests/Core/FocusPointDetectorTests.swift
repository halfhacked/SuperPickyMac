import Testing
import Foundation
import CoreGraphics
import SuperPickyInference
@testable import SuperPicky

@Suite struct FocusPointDetectorTests {
    // MARK: - Weight tier values

    @Test func headFocusWeights() {
        let w = FocusPointDetector.FocusWeights.headFocus
        #expect(w.sharpness == 1.1)
        #expect(w.aesthetics == 1.0)
    }

    @Test func segFocusWeights() {
        let w = FocusPointDetector.FocusWeights.segFocus
        #expect(w.sharpness == 0.9)
        #expect(w.aesthetics == 1.0)
    }

    @Test func bboxFocusWeights() {
        let w = FocusPointDetector.FocusWeights.bboxFocus
        #expect(w.sharpness == 0.8)
        #expect(w.aesthetics == 0.9)
    }

    @Test func missedFocusWeights() {
        let w = FocusPointDetector.FocusWeights.missedFocus
        #expect(w.sharpness == 0.5)
        #expect(w.aesthetics == 0.8)
    }

    @Test func unfocusedWeights() {
        let w = FocusPointDetector.FocusWeights.unfocused
        #expect(w.sharpness == 0.8)
        #expect(w.aesthetics == 0.9)
    }

    @Test func unknownWeights() {
        let w = FocusPointDetector.FocusWeights.unknown
        #expect(w.sharpness == 1.0)
        #expect(w.aesthetics == 1.0)
    }

    // MARK: - No focus point → unknown

    @Test func noFocusPointReturnsUnknown() {
        let result = FocusPointDetector.computeWeights(
            focusPoint: nil,
            isFocused: true,
            birdBbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            eyeCenter: (x: 0.5, y: 0.5),
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        #expect(result.sharpness == 1.0)
        #expect(result.aesthetics == 1.0)
    }

    // MARK: - Unfocused detection

    @Test func unfocusedReturnsUnfocusedWeights() {
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.5, y: 0.5),
            isFocused: false,
            birdBbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            eyeCenter: (x: 0.5, y: 0.5),
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - Focus outside bbox → missed

    @Test func focusOutsideBboxReturnsMissed() {
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.1, y: 0.1),
            isFocused: true,
            birdBbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            eyeCenter: (x: 0.5, y: 0.5),
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        #expect(result.sharpness == 0.5)
        #expect(result.aesthetics == 0.8)
    }

    // MARK: - Focus inside head circle → head

    @Test func focusInsideHeadReturnsHead() {
        // Bbox at (0.3, 0.3, 0.4, 0.4), eye at center of crop (0.5, 0.5)
        // Eye in image coords: (0.3 + 0.5*0.4, 0.3 + 0.5*0.4) = (0.5, 0.5)
        // headRadius = 0.15 * max(0.4, 0.4) = 0.06
        // Focus at (0.5, 0.5) → distance 0 → inside head
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.5, y: 0.5),
            isFocused: true,
            birdBbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            eyeCenter: (x: 0.5, y: 0.5),
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        #expect(result.sharpness == 1.1)
        #expect(result.aesthetics == 1.0)
    }

    // MARK: - Focus in bbox but not head, no seg mask → bbox

    @Test func focusInBboxNoSegMaskReturnsBbox() {
        // Bbox at (0.2, 0.2, 0.6, 0.6), eye at (0.5, 0.3) in crop space
        // Eye in image: (0.2 + 0.5*0.6, 0.2 + 0.3*0.6) = (0.5, 0.38)
        // headRadius = 0.15 * 0.6 = 0.09
        // Focus at (0.7, 0.7) → inside bbox (0.2-0.8, 0.2-0.8) but far from eye
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.7, y: 0.7),
            isFocused: true,
            birdBbox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            eyeCenter: (x: 0.5, y: 0.3),
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - Seg mask tests

    @Test func focusInSegMaskReturnsSeg() {
        // Create a 4x4 mask where top-left quadrant is bird (value=1)
        // Mask covers full image at model resolution
        let maskWidth = 4
        let maskHeight = 4
        var maskData = Data(repeating: 0, count: maskWidth * maskHeight)
        // Set top-left quadrant to 1 (bird pixels)
        for y in 0..<2 {
            for x in 0..<2 {
                maskData[y * maskWidth + x] = 1
            }
        }

        // Bbox covers entire image, eye in top-left corner at crop (0.1, 0.1)
        // Eye in image: (0.0 + 0.1*1.0, 0.0 + 0.1*1.0) = (0.1, 0.1)
        // headRadius = 0.15 * 1.0 = 0.15
        // Focus at (0.4, 0.4) → inside bbox, inside seg mask (top-left quadrant),
        //   but outside head circle (distance from (0.1,0.1) = sqrt(0.09+0.09) ≈ 0.424 > 0.15)
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.4, y: 0.4),
            isFocused: true,
            birdBbox: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
            eyeCenter: (x: 0.1, y: 0.1),
            headRadiusFraction: 0.15,
            segMask: maskData,
            maskWidth: maskWidth,
            maskHeight: maskHeight
        )
        #expect(result.sharpness == 0.9)
        #expect(result.aesthetics == 1.0)
    }

    @Test func focusInBboxButNotInSegMaskReturnsBbox() {
        // 4x4 mask, only top-left pixel is bird
        let maskWidth = 4
        let maskHeight = 4
        var maskData = Data(repeating: 0, count: maskWidth * maskHeight)
        maskData[0] = 1  // Only (0,0) is bird

        // Focus at (0.8, 0.8) → inside bbox (full image), not in seg mask, not in head
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.8, y: 0.8),
            isFocused: true,
            birdBbox: CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0),
            eyeCenter: (x: 0.1, y: 0.1),
            headRadiusFraction: 0.05,
            segMask: maskData,
            maskWidth: maskWidth,
            maskHeight: maskHeight
        )
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - Sony FocusLocation parsing

    @Test func sonyParsesFocusLocationFromStringForm() {
        // Sony A1 MakerNote (exiftool string form): "5616 3744 2812 1885"
        let makerNote: [String: Any] = [
            "FocusLocation": "5616 3744 2812 1885",
            "FocusFrameSize": "224 224 1"
        ]
        let r = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1)!
        #expect(abs(r.x - Float(2812) / Float(5616)) < 0.0001)
        #expect(abs(r.y - Float(1885) / Float(3744)) < 0.0001)
        #expect(r.isFocused == true)
    }

    @Test func sonyParsesFocusLocationFromArrayForm() {
        // Same data but as [NSNumber] array (Apple ImageIO sometimes
        // surfaces multi-int MakerNote tags this way).
        let makerNote: [String: Any] = [
            "FocusLocation": [NSNumber(value: 5616), NSNumber(value: 3744),
                              NSNumber(value: 2812), NSNumber(value: 1885)],
            "FocusFrameSize": [NSNumber(value: 224), NSNumber(value: 224), NSNumber(value: 1)]
        ]
        let r = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1)!
        #expect(abs(r.x - 0.5006) < 0.001)
        #expect(r.isFocused == true)
    }

    @Test func sonyTreatsValidityZeroAsUnfocused() {
        // FocusFrameSize[2] = 0 → AF didn't lock
        let makerNote: [String: Any] = [
            "FocusLocation": "5616 3744 2812 1885",
            "FocusFrameSize": "224 224 0"
        ]
        let r = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1)!
        #expect(r.isFocused == false)
    }

    @Test func sonyDefaultsToFocusedWhenFrameSizeMissing() {
        // No FocusFrameSize tag → conservatively assume focused (matches
        // Python's `focus_result = 1` default).
        let makerNote: [String: Any] = ["FocusLocation": "5616 3744 2812 1885"]
        let r = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1)!
        #expect(r.isFocused == true)
    }

    @Test func sonyRejectsManualFocus() {
        // FocusMode = "1" (Sony's MF code) → no AF data
        let makerNote: [String: Any] = [
            "FocusMode": "1",
            "FocusLocation": "5616 3744 2812 1885"
        ]
        #expect(FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1) == nil)
    }

    @Test func sonyRejectsManualFocusByName() {
        // Some Sony bodies surface "Manual" as a string label
        let makerNote: [String: Any] = [
            "FocusMode": "Manual",
            "FocusLocation": "5616 3744 2812 1885"
        ]
        #expect(FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1) == nil)
    }

    @Test func sonyReturnsNilWhenFocusLocationMissing() {
        let makerNote: [String: Any] = ["FocusFrameSize": "224 224 1"]
        #expect(FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1) == nil)
    }

    @Test func sonyAppliesOrientationCorrection() {
        // Portrait CW (orientation=6): (x, y) → (y, 1-x)
        let makerNote: [String: Any] = ["FocusLocation": "5616 3744 1404 936"]
        let landscape = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 1)!
        let portrait  = FocusPointDetector.parseSonyFocusPoint(makerNote: makerNote, orientation: 6)!
        #expect(abs(portrait.x - landscape.y) < 0.001)
        #expect(abs(portrait.y - (1 - landscape.x)) < 0.001)
    }

    // MARK: - headRadiusFraction helper

    @Test func headRadiusFractionUsesEyeBeakDistanceWhenBeakVisible() {
        // eye-beak distance = √((0.6-0.5)² + 0²) = 0.10 → ×1.2 = 0.12.
        // Different from the 0.15 no-beak fallback; confirms the helper
        // actually uses the keypoint geometry instead of returning the
        // constant.
        let r = FocusPointDetector.headRadiusFraction(
            beakVisibility: 0.9,
            eye: (x: 0.5, y: 0.5),
            beak: (x: 0.6, y: 0.5)
        )
        #expect(abs(r - 0.12) < 0.001)
    }

    @Test func headRadiusFractionFallsBackWhenBeakHidden() {
        let r = FocusPointDetector.headRadiusFraction(
            beakVisibility: 0.1,
            eye: (x: 0.5, y: 0.5),
            beak: (x: 0.6, y: 0.5)
        )
        #expect(r == 0.15)
    }

    @Test func headRadiusFractionTreatsBeakBelowThresholdAsHidden() {
        let r = FocusPointDetector.headRadiusFraction(
            beakVisibility: InferenceConstants.keypointVisibilityThreshold - 0.01,
            eye: (x: 0.5, y: 0.5),
            beak: (x: 0.5, y: 0.5)
        )
        #expect(r == 0.15)
    }

    // MARK: - No eye center: head check skipped, falls through to seg/bbox

    @Test func noEyeCenterSkipsHeadCheck() {
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.5, y: 0.5),
            isFocused: true,
            birdBbox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            eyeCenter: nil,
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        // No eye → can't be head, no seg mask → bbox
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - Edge: focus exactly on bbox boundary

    @Test func focusOnBboxEdgeIsInsideBbox() {
        // CGRect.contains includes min edges but excludes max edges
        // Focus at bbox origin (0.3, 0.3) should be inside
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.3, y: 0.3),
            isFocused: true,
            birdBbox: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
            eyeCenter: nil,
            headRadiusFraction: 0.15,
            segMask: nil,
            maskWidth: 0,
            maskHeight: 0
        )
        // Inside bbox, no eye, no mask → bbox weights
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - Empty seg mask treated as no mask

    @Test func emptySegMaskTreatedAsNoMask() {
        let result = FocusPointDetector.computeWeights(
            focusPoint: (x: 0.5, y: 0.5),
            isFocused: true,
            birdBbox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6),
            eyeCenter: nil,
            headRadiusFraction: 0.15,
            segMask: Data(),  // empty
            maskWidth: 4,
            maskHeight: 4
        )
        #expect(result.sharpness == 0.8)
        #expect(result.aesthetics == 0.9)
    }

    // MARK: - SubjectArea EXIF parsing

    @Test func parseSubjectAreaTwoValues() {
        // [x, y] pixel coords with image dimensions
        let result = FocusPointDetector.parseSubjectArea(
            subjectArea: [3000, 2000],
            imageWidth: 6000,
            imageHeight: 4000
        )
        #expect(result != nil)
        #expect(result!.x == 0.5)
        #expect(result!.y == 0.5)
    }

    @Test func parseSubjectAreaThreeValues() {
        // [x, y, diameter]
        let result = FocusPointDetector.parseSubjectArea(
            subjectArea: [1500, 1000, 200],
            imageWidth: 6000,
            imageHeight: 4000
        )
        #expect(result != nil)
        #expect(result!.x == 0.25)
        #expect(result!.y == 0.25)
    }

    @Test func parseSubjectAreaFourValues() {
        // [x, y, w, h]
        let result = FocusPointDetector.parseSubjectArea(
            subjectArea: [6000, 4000, 100, 100],
            imageWidth: 6000,
            imageHeight: 4000
        )
        #expect(result != nil)
        #expect(result!.x == 1.0)
        #expect(result!.y == 1.0)
    }

    @Test func parseSubjectAreaZeroDimensions() {
        let result = FocusPointDetector.parseSubjectArea(
            subjectArea: [100, 100],
            imageWidth: 0,
            imageHeight: 0
        )
        #expect(result == nil)
    }

    @Test func parseSubjectAreaTooFewValues() {
        let result = FocusPointDetector.parseSubjectArea(
            subjectArea: [100],
            imageWidth: 6000,
            imageHeight: 4000
        )
        #expect(result == nil)
    }

    // MARK: - Orientation correction

    @Test func orientationNormal() {
        let result = FocusPointDetector.applyOrientationCorrection(x: 0.3, y: 0.7, orientation: 1)
        #expect(result.x == 0.3)
        #expect(result.y == 0.7)
    }

    @Test func orientationRotate90CW() {
        // Orientation 6: (x,y) → (y, 1-x)
        let result = FocusPointDetector.applyOrientationCorrection(x: 0.3, y: 0.7, orientation: 6)
        #expect(abs(result.x - 0.7) < 0.001)
        #expect(abs(result.y - 0.7) < 0.001)
    }

    @Test func orientationRotate270CW() {
        // Orientation 8: (x,y) → (1-y, x)
        let result = FocusPointDetector.applyOrientationCorrection(x: 0.3, y: 0.7, orientation: 8)
        #expect(abs(result.x - 0.3) < 0.001)
        #expect(abs(result.y - 0.3) < 0.001)
    }
}

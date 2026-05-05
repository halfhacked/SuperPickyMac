import AVFoundation
import SwiftUI

/// Debug overlay that draws the geometry the sharpness pipeline measures
/// over the displayed photo.
///
/// - **Red bbox** — YOLO bird bounding box. Sharpness is computed only
///   inside this region.
/// - **Yellow circle** — head circle (eye-centered, radius =
///   eye-beak distance × 1.2 when beak visible, else 15 % of the
///   smart-square crop's max side). The actual region Tenengrad
///   averages over.
/// - **Blue dot** — predicted eye location used as the circle centre.
///   When eye visibility < 0.5 ("bothHidden") this is a fallback
///   prediction and the circle's anatomical accuracy is suspect —
///   exactly the case this overlay diagnoses.
///
/// Coordinates: bbox is normalized to the original image. Eye/beak
/// keypoints are normalized to the smartSquareBirdCrop output canvas,
/// which may include black letterbox bars on near-edge subjects. We
/// reproduce that pixel-exact crop math in `cropToImageNorm` so the
/// rendered circle/dot land on the same pixels the metric measures.
struct SharpnessOverlay: View {
    let photo: Photo
    /// Natural pixel size of the displayed image (NSImage.size). Needed
    /// to resolve aspect-fit margins inside the overlay's geo, and to
    /// reproduce the smart-square-crop letterbox math.
    let imageSize: CGSize

    private static let radiusMultiplier: CGFloat = 1.2
    private static let noBeakRadiusRatio: CGFloat = 0.15
    private static let cropPaddingFactor: CGFloat = 1.15

    var body: some View {
        GeometryReader { geo in
            if let bbox = bbox, imageSize.width > 0, imageSize.height > 0 {
                let imgRect = AVMakeRect(
                    aspectRatio: imageSize,
                    insideRect: CGRect(origin: .zero, size: geo.size)
                )
                let bboxRect = CGRect(
                    x: imgRect.minX + bbox.minX * imgRect.width,
                    y: imgRect.minY + bbox.minY * imgRect.height,
                    width:  bbox.width  * imgRect.width,
                    height: bbox.height * imgRect.height
                )
                Rectangle()
                    .stroke(.red, lineWidth: 1.5)
                    .frame(width: bboxRect.width, height: bboxRect.height)
                    .position(x: bboxRect.midX, y: bboxRect.midY)

                if let eye = selectedEyeInCropCoords,
                   let eyeImageNorm = cropToImageNorm(eye, bbox: bbox) {
                    let eyeOnScreen = CGPoint(
                        x: imgRect.minX + eyeImageNorm.x * imgRect.width,
                        y: imgRect.minY + eyeImageNorm.y * imgRect.height
                    )
                    // Head radius is in IMAGE PIXELS (smart-square crop is
                    // in image-pixel space). Convert to screen via the
                    // imgRect-to-image scale.
                    let scale = imgRect.width / imageSize.width
                    let radiusPx = headRadiusInImagePx(eyeCrop: eye, bbox: bbox)
                    let radiusOnScreen = radiusPx * scale
                    Circle()
                        .stroke(.yellow, lineWidth: 1.5)
                        .frame(width: radiusOnScreen * 2,
                                height: radiusOnScreen * 2)
                        .position(eyeOnScreen)
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                        .position(eyeOnScreen)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Reproduce `CGImage.smartSquareBirdCrop`'s pixel-exact geometry —
    /// including bbox-to-image clamping and the letterbox padding that
    /// makes the cropped region square — and return the keypoint's
    /// position in image-normalized [0, 1] coords.
    ///
    /// The keypoint model received an image at 1280-max-side, but bbox is
    /// normalized so doing the math at the displayed image's pixel size
    /// gives the same crop *normalized* coordinate.
    ///
    /// TODO: this is the third copy of `smartSquareBirdCrop`'s integer
    /// geometry (others in `CGImageExtensions.swift` and
    /// `PipelineCoordinator.birdCropAlignedSegMask`). Lift to a shared
    /// `SmartSquareCropGeometry` struct in CGImageExtensions in a
    /// follow-up PR.
    private func cropToImageNorm(_ cropPoint: (x: Float, y: Float),
                                  bbox: CGRect) -> CGPoint? {
        let imgW = imageSize.width, imgH = imageSize.height
        let px1 = floor(bbox.origin.x * imgW)
        let py1 = floor(bbox.origin.y * imgH)
        let px2 = ceil((bbox.origin.x + bbox.size.width)  * imgW)
        let py2 = ceil((bbox.origin.y + bbox.size.height) * imgH)
        let bboxW = px2 - px1, bboxH = py2 - py1
        guard bboxW > 0, bboxH > 0 else { return nil }
        let maxSide = max(bboxW, bboxH)
        let target = floor(maxSide * Self.cropPaddingFactor)
        let cx = (px1 + px2) / 2, cy = (py1 + py2) / 2
        let half = floor(target / 2)
        let cropX1 = max(0, cx - half), cropY1 = max(0, cy - half)
        let cropX2 = min(imgW, cx + half), cropY2 = min(imgH, cy + half)
        let cropW = cropX2 - cropX1, cropH = cropY2 - cropY1
        guard cropW > 0, cropH > 0 else { return nil }
        let sqSize = max(cropW, cropH)
        // Letterbox offset of the image content inside the square canvas.
        let offX = floor((sqSize - cropW) / 2)
        let offY = floor((sqSize - cropH) / 2)

        let cpx = CGFloat(cropPoint.x) * sqSize
        let cpy = CGFloat(cropPoint.y) * sqSize
        let imgPx = cropX1 + (cpx - offX)
        let imgPy = cropY1 + (cpy - offY)
        return CGPoint(x: imgPx / imgW, y: imgPy / imgH)
    }

    /// Head circle radius in image pixels (mirrors `HeadSharpness`'s
    /// 3-branch fallback at the smart-square-crop's pixel resolution).
    private func headRadiusInImagePx(eyeCrop: (x: Float, y: Float),
                                      bbox: CGRect) -> CGFloat {
        let imgW = imageSize.width, imgH = imageSize.height
        let bboxW = bbox.width * imgW, bboxH = bbox.height * imgH
        let target = max(bboxW, bboxH) * Self.cropPaddingFactor
        let beakVisible = (photo.beakVis ?? 0) >= HeadSharpness.visibilityThreshold
        if beakVisible, let bx = photo.beakX, let by = photo.beakY {
            let dx = CGFloat(eyeCrop.x - bx), dy = CGFloat(eyeCrop.y - by)
            // Eye-beak distance in crop-canvas pixels = norm * target.
            return hypot(dx, dy) * target * Self.radiusMultiplier
        }
        return target * Self.noBeakRadiusRatio
    }

    /// Bird bbox in image-normalized [0, 1] coords. The DB stores the
    /// JSON `[x1, y1, x2, y2]` — see `PipelineCoordinator.encodeJSON` of
    /// `bird.bbox`'s minX/minY/maxX/maxY.
    private var bbox: CGRect? {
        guard let json = photo.birdBboxJSON,
              let data = json.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [Double],
              arr.count == 4 else {
            return nil
        }
        let x = arr[0], y = arr[1], w = arr[2] - arr[0], h = arr[3] - arr[1]
        guard w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Picked eye in bird-crop normalized coords. Delegates to
    /// `HeadSharpness.pickEye` so the overlay can't disagree with the
    /// metric's selection rule.
    private var selectedEyeInCropCoords: (x: Float, y: Float)? {
        guard let pick = HeadSharpness.pickEye(
            leftEyeX: photo.leftEyeX, leftEyeY: photo.leftEyeY, leftEyeVis: photo.leftEyeVis,
            rightEyeX: photo.rightEyeX, rightEyeY: photo.rightEyeY, rightEyeVis: photo.rightEyeVis,
            beakX: photo.beakX, beakY: photo.beakY
        ) else { return nil }
        return (pick.x, pick.y)
    }
}

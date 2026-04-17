// YOLOBirdDetector.swift
//
// Wraps the CoreML yolo11l-seg model for bird detection.
//
// Input:  Any-size CGImage (letterboxed to 640×640 internally)
// Output: [Detection] — normalized bbox [0,1] in original-image space,
//         confidence, and a 160×160 binary segmentation mask.
//
// Output tensor names (from coremltools inspection of exported mlpackage):
//   var_2317  [1, 116, 8400]  — bbox (4) + class scores (80) + mask coefs (32) per anchor
//   var_2355  [1, 32, 160, 160] — mask prototypes
//
// Class filtering: COCO class 14 = bird (single-class pass-through for this model)
// NMS:  Greedy, IoU threshold 0.45 (ultralytics default for seg)
// Conf: 0.25 (ultralytics default)
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each predict() call allocates fresh pixel buffers and intermediate arrays.

import CoreML
import CoreGraphics
import Foundation
import os

public final class YOLOBirdDetector: @unchecked Sendable {

    // MARK: - Constants (match ultralytics defaults + COCO class map)
    public static let imageSize = InferenceConstants.yoloInputSize
    public static let birdClassID = InferenceConstants.yoloBirdClassID
    public static let confThreshold = InferenceConstants.yoloConfThreshold
    public static let nmsIoUThreshold = InferenceConstants.yoloNMSThreshold

    private static let numClasses = 80
    private static let numMaskCoefs = 32
    private static let numAnchors = 8400
    private static let maskH = 160
    private static let maskW = 160

    // Output tensor names from coremltools ONNX→CoreML conversion
    private static let outputBoxesName = "var_2317"
    private static let outputMasksName = "var_2355"

    // MARK: - Public types

    public struct Detection: Sendable {
        /// Normalized bounding box in original-image space [0,1].
        public let x1: Float, y1: Float, x2: Float, y2: Float
        public let confidence: Float
        /// 160×160 binary mask (uint8: 0=background, 1=bird), row-major.
        /// Coordinates are in letterboxed YOLO space, not original-image space.
        public let maskData: Data
    }

    // MARK: - State

    private let model: MLModel
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "YOLODetector")

    // MARK: - Init

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        // YOLO11l-seg contains ops the MPSGraph backend can't lower
        // (MLIR pass manager assertion in MetalPerformanceShadersGraph on
        // macOS 26). `.cpuAndGPU` crashes at load. `.all` lets CoreML
        // pick the backend that works — in practice ANE.
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Inference

    public func predict(image: CGImage) throws -> [Detection] {
        let origW = Float(image.width)
        let origH = Float(image.height)
        let targetSize = Self.imageSize

        // 1. Letterbox
        let letterboxStart = DispatchTime.now()
        let (scale, padLeft, padTop) = Self.letterboxParams(origW: origW, origH: origH,
                                                             targetSize: Float(targetSize))
        let pixelBuffer = try Self.renderLetterboxed(image: image, targetSize: targetSize,
                                                      scale: scale, padLeft: padLeft, padTop: padTop)
        let letterboxMs = Self.elapsedMs(since: letterboxStart)

        // 2. Inference
        let inferStart = DispatchTime.now()
        let input = try MLDictionaryFeatureProvider(
            dictionary: ["image": MLFeatureValue(pixelBuffer: pixelBuffer)]
        )
        let output = try autoreleasepool { try model.prediction(from: input) }
        let inferMs = Self.elapsedMs(since: inferStart)

        guard let boxesMLA = output.featureValue(for: Self.outputBoxesName)?.multiArrayValue,
              let masksMLA = output.featureValue(for: Self.outputMasksName)?.multiArrayValue else {
            logger.error("YOLO: missing expected output tensors (var_2317 / var_2355)")
            return []
        }

        // 3. Parse candidates using strides for correct memory layout handling
        let parseStart = DispatchTime.now()
        let channelStride = boxesMLA.strides[1].intValue  // stride from channel j to j+1
        let anchorStride  = boxesMLA.strides[2].intValue  // stride from anchor i to i+1 (usually 1)

        guard boxesMLA.dataType == .float32, masksMLA.dataType == .float32 else {
            logger.error("YOLO: unexpected tensor dtype (expected float32)")
            return []
        }

        let boxes = boxesMLA.dataPointer.bindMemory(to: Float.self,
                                                     capacity: boxesMLA.count)
        let protos = masksMLA.dataPointer.bindMemory(to: Float.self,
                                                      capacity: masksMLA.count)

        struct Candidate {
            var cx, cy, w, h, conf: Float
            var coefs: [Float]
        }

        var candidates = [Candidate]()
        candidates.reserveCapacity(64)

        let birdChannel = 4 + Self.birdClassID
        let maskStart   = 4 + Self.numClasses

        for i in 0..<Self.numAnchors {
            let birdScore = boxes[birdChannel * channelStride + i * anchorStride]
            guard birdScore >= Self.confThreshold else { continue }

            let cx = boxes[0 * channelStride + i * anchorStride]
            let cy = boxes[1 * channelStride + i * anchorStride]
            let w  = boxes[2 * channelStride + i * anchorStride]
            let h  = boxes[3 * channelStride + i * anchorStride]

            var coefs = [Float](repeating: 0, count: Self.numMaskCoefs)
            for k in 0..<Self.numMaskCoefs {
                coefs[k] = boxes[(maskStart + k) * channelStride + i * anchorStride]
            }
            candidates.append(Candidate(cx: cx, cy: cy, w: w, h: h, conf: birdScore, coefs: coefs))
        }

        let parseMs = Self.elapsedMs(since: parseStart)

        // 4. NMS
        let nmsStart = DispatchTime.now()
        candidates.sort { $0.conf > $1.conf }
        var kept = [Candidate]()
        for c in candidates {
            let suppress = kept.contains { k in
                return iou(ax1: c.cx - c.w/2, ay1: c.cy - c.h/2,
                           ax2: c.cx + c.w/2, ay2: c.cy + c.h/2,
                           bx1: k.cx - k.w/2, by1: k.cy - k.h/2,
                           bx2: k.cx + k.w/2, by2: k.cy + k.h/2) > Self.nmsIoUThreshold
            }
            if !suppress { kept.append(c) }
        }

        let nmsMs = Self.elapsedMs(since: nmsStart)

        // 5. Un-letterbox + decode masks
        let maskStart2 = DispatchTime.now()
        let result = kept.map { c in
            let x1 = clamp01((c.cx - c.w/2 - padLeft) / scale / origW)
            let y1 = clamp01((c.cy - c.h/2 - padTop)  / scale / origH)
            let x2 = clamp01((c.cx + c.w/2 - padLeft) / scale / origW)
            let y2 = clamp01((c.cy + c.h/2 - padTop)  / scale / origH)
            let mask = Self.decodeMask(coefs: c.coefs, protos: protos)
            return Detection(x1: x1, y1: y1, x2: x2, y2: y2, confidence: c.conf, maskData: mask)
        }
        let maskMs = Self.elapsedMs(since: maskStart2)
        logger.debug("yolo.predict letterbox=\(letterboxMs, privacy: .public)ms infer=\(inferMs, privacy: .public)ms parse=\(parseMs, privacy: .public)ms nms=\(nmsMs, privacy: .public)ms mask=\(maskMs, privacy: .public)ms candidates=\(candidates.count, privacy: .public) kept=\(result.count, privacy: .public)")
        return result
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Private helpers

    /// Compute letterbox scaling params: scale factor + symmetric padding.
    static func letterboxParams(origW: Float, origH: Float, targetSize: Float)
        -> (scale: Float, padLeft: Float, padTop: Float) {
        let scale = min(targetSize / origW, targetSize / origH)
        let newW  = origW * scale
        let newH  = origH * scale
        return (scale, (targetSize - newW) / 2, (targetSize - newH) / 2)
    }

    /// Render `image` letterboxed onto a gray (114,114,114) 640×640 pixel buffer.
    private static func renderLetterboxed(image: CGImage, targetSize: Int,
                                           scale: Float, padLeft: Float, padTop: Float)
        throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetSize,
            kCVPixelBufferHeightKey: targetSize,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(nil, targetSize, targetSize,
                                          kCVPixelFormatType_32BGRA,
                                          attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw YOLOBirdDetectorError.pixelBufferCreationFailed
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: targetSize,
            height: targetSize,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            // BGRA little-endian matches kCVPixelFormatType_32BGRA
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                        CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw YOLOBirdDetectorError.contextCreationFailed
        }

        // Ultralytics letterbox grey (114/255)
        ctx.setFillColor(red: 114/255, green: 114/255, blue: 114/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))

        let newW = Float(image.width) * scale
        let newH = Float(image.height) * scale
        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.draw(image, in: CGRect(x: CGFloat(padLeft), y: CGFloat(padTop),
                                   width: CGFloat(newW), height: CGFloat(newH)))
        return pixelBuffer
    }

    /// Decode per-detection mask: mask_coefs (32) × prototypes (32×160×160) → sigmoid → threshold.
    /// Returns 160×160 uint8 array (0=background, 1=bird).
    private static func decodeMask(coefs: [Float], protos: UnsafePointer<Float>) -> Data {
        let h = maskH, w = maskW
        var result = [UInt8](repeating: 0, count: h * w)
        let hw = h * w
        for y in 0..<h {
            for x in 0..<w {
                var val: Float = 0
                let pixel = y * w + x
                for k in 0..<numMaskCoefs {
                    val += coefs[k] * protos[k * hw + pixel]
                }
                result[pixel] = (1.0 / (1.0 + exp(-val))) > 0.5 ? 1 : 0
            }
        }
        return Data(result)
    }

    // MARK: - IoU

    private func iou(ax1: Float, ay1: Float, ax2: Float, ay2: Float,
                     bx1: Float, by1: Float, bx2: Float, by2: Float) -> Float {
        let ix1 = max(ax1, bx1), iy1 = max(ay1, by1)
        let ix2 = min(ax2, bx2), iy2 = min(ay2, by2)
        let iw = max(0, ix2 - ix1), ih = max(0, iy2 - iy1)
        let inter = iw * ih
        let aArea = (ax2 - ax1) * (ay2 - ay1)
        let bArea = (bx2 - bx1) * (by2 - by1)
        let union = aArea + bArea - inter
        return union > 0 ? inter / union : 0
    }

    private func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
}

// MARK: - Errors

public enum YOLOBirdDetectorError: Error {
    case pixelBufferCreationFailed
    case contextCreationFailed
}

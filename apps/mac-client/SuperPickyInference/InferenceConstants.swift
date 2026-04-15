// InferenceConstants.swift
//
// Central source of every Python-sourced magic number the native inference
// pipeline needs. Every constant cites its Python source so a future drift
// check is a single-file diff.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 4A "Model hyperparameters" for the complete audit.

import Foundation
import simd

public enum InferenceConstants {
    // MARK: OSEA / species classifier
    // Source: python-server/inference/species.py:7-8
    public static let regionalSpeciesThreshold: Float = 80.0
    public static let globalSpeciesThreshold: Float = 90.0

    // Source: preen/birdid/osea_classifier.py:104
    public static let oseaTemperature: Float = 0.9

    // Source: preen/birdid/osea_classifier.py:177
    // Model outputs 11000 logits; we trim to the 10964 used species.
    public static let oseaNumClasses = 10964

    // Source: preen/birdid/osea_classifier.py:98
    public static let oseaInputSize = 224

    // Source: preen/birdid/osea_classifier.py:231 (dead filter in practice, preserved for parity)
    public static let oseaMinConfidencePercent: Float = 0.3

    // MARK: YOLO
    // Source: preen/detector.py:11 (COCO dataset bird class)
    public static let yoloBirdClassID = 14

    // Source: ultralytics defaults
    public static let yoloInputSize = 640
    public static let yoloNMSThreshold: Float = 0.45
    public static let yoloConfThreshold: Float = 0.25

    // MARK: Keypoint
    // Source: ~/projects/SuperPicky/core/keypoint_detector.py:71-72
    public static let keypointInputSize = 416
    public static let keypointVisibilityThreshold: Float = 0.3

    // MARK: Flight
    // Source: ~/projects/SuperPicky/core/flight_detector.py:38-39
    public static let flightInputSize = 384
    public static let flightThreshold: Float = 0.5

    // MARK: Smart crop
    // Source: preen/detector.py:76
    public static let smartCropPaddingFactor: Float = 1.15

    // MARK: ImageNet normalization (standard torchvision)
    public static let imageNetMean: SIMD3<Float> = SIMD3<Float>(0.485, 0.456, 0.406)
    public static let imageNetStd: SIMD3<Float> = SIMD3<Float>(0.229, 0.224, 0.225)
}

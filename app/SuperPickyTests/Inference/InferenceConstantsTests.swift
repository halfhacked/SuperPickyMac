import Testing
@testable import SuperPickyInference

@Suite("InferenceConstants")
struct InferenceConstantsTests {
    // MARK: - OSEA / species classifier

    @Test("OSEA regional species threshold matches python-server/inference/species.py")
    func regionalThreshold() {
        #expect(InferenceConstants.regionalSpeciesThreshold == 80.0)
    }

    @Test("OSEA global species threshold matches python-server/inference/species.py")
    func globalThreshold() {
        #expect(InferenceConstants.globalSpeciesThreshold == 90.0)
    }

    @Test("OSEA temperature matches preen/birdid/osea_classifier.py")
    func temperature() {
        #expect(InferenceConstants.oseaTemperature == 0.9)
    }

    @Test("OSEA class count is 10964")
    func numClasses() {
        #expect(InferenceConstants.oseaNumClasses == 10964)
    }

    @Test("OSEA input size is 224")
    func oseaInputSize() {
        #expect(InferenceConstants.oseaInputSize == 224)
    }

    @Test("OSEA min confidence percent is 0.3 (preserved for parity)")
    func oseaMinConfidencePercent() {
        #expect(InferenceConstants.oseaMinConfidencePercent == 0.3)
    }

    // MARK: - YOLO

    @Test("YOLO bird class ID is 14 (COCO)")
    func birdClassID() {
        #expect(InferenceConstants.yoloBirdClassID == 14)
    }

    @Test("YOLO input size is 640")
    func yoloInputSize() {
        #expect(InferenceConstants.yoloInputSize == 640)
    }

    @Test("YOLO NMS threshold is 0.45")
    func yoloNMSThreshold() {
        #expect(InferenceConstants.yoloNMSThreshold == 0.45)
    }

    @Test("YOLO confidence threshold is 0.25")
    func yoloConfThreshold() {
        #expect(InferenceConstants.yoloConfThreshold == 0.25)
    }

    // MARK: - Keypoint

    @Test("Keypoint input size is 416")
    func keypointInputSize() {
        #expect(InferenceConstants.keypointInputSize == 416)
    }

    @Test("Keypoint visibility threshold is 0.3")
    func keypointVisibilityThreshold() {
        #expect(InferenceConstants.keypointVisibilityThreshold == 0.3)
    }

    // MARK: - Flight

    @Test("Flight input size is 384")
    func flightInputSize() {
        #expect(InferenceConstants.flightInputSize == 384)
    }

    @Test("Flight threshold is 0.5")
    func flightThreshold() {
        #expect(InferenceConstants.flightThreshold == 0.5)
    }

    // MARK: - Smart crop

    @Test("Smart crop padding factor is 1.15 (15% pad)")
    func smartCropPaddingFactor() {
        #expect(InferenceConstants.smartCropPaddingFactor == 1.15)
    }

    // MARK: - ImageNet normalization

    @Test("ImageNet mean matches torchvision default")
    func imageNetMean() {
        #expect(InferenceConstants.imageNetMean == SIMD3<Float>(0.485, 0.456, 0.406))
    }

    @Test("ImageNet std matches torchvision default")
    func imageNetStd() {
        #expect(InferenceConstants.imageNetStd == SIMD3<Float>(0.229, 0.224, 0.225))
    }
}

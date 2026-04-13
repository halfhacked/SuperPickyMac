import Testing
import Foundation
@testable import SuperPicky

@Suite struct InferenceResponseParsingTests {
    @Test func parseDetectionResponse() throws {
        let json = """
        {
            "birds": [{
                "bbox": [0.1, 0.2, 0.6, 0.8],
                "confidence": 0.94,
                "mask": "AQID"
            }]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(DetectionResult.self, from: json)
        #expect(result.birds.count == 1)
        #expect(result.birds[0].confidence == 0.94)
        #expect(abs(result.birds[0].bbox.origin.x - 0.1) < 0.001)
        #expect(abs(result.birds[0].bbox.size.width - 0.5) < 0.001)
    }

    @Test func parseKeypointResponse() throws {
        let json = """
        {
            "keypoints": {
                "left_eye": {"x": 0.42, "y": 0.31, "visibility": 0.87},
                "right_eye": {"x": 0.58, "y": 0.33, "visibility": 0.92},
                "beak": {"x": 0.50, "y": 0.45, "visibility": 0.95}
            }
        }
        """.data(using: .utf8)!

        let wrapper = try JSONDecoder().decode(KeypointResponseWrapper.self, from: json)
        let result = wrapper.keypoints
        #expect(result.leftEye.visibility == 0.87)
        #expect(result.bestEyeVisibility == 0.92)
        #expect(result.allKeypointsHidden == false)
    }

    @Test func parseFlightResponse() throws {
        let json = """
        {"is_flying": true, "confidence": 0.83}
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(FlightResult.self, from: json)
        #expect(result.isFlying == true)
        #expect(result.confidence == 0.83)
    }

    @Test func parseHealthResponse() throws {
        let json = """
        {
            "status": "ready",
            "models_loaded": ["yolo", "topiq", "keypoint", "flight", "osea"],
            "device": "mps",
            "version": "1.0.0"
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ServerHealth.self, from: json)
        #expect(result.status == "ready")
        #expect(result.modelsLoaded.count == 5)
    }
}

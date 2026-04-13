import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class HTTPInferenceClient: InferenceClient {
    private let baseURL: URL
    private let session: URLSession

    init(port: Int = 8420) {
        self.baseURL = URL(string: "http://localhost:\(port)")!
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        self.session = URLSession(configuration: config)
    }

    func detect(image: CGImage) async throws -> DetectionResult {
        let data = try jpegData(from: image)
        let responseData = try await postMultipart(endpoint: "detect", imageData: data)
        return try decode(DetectionResult.self, from: responseData)
    }

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        let data = try jpegData(from: image)
        let responseData = try await postMultipart(endpoint: "aesthetics", imageData: data)
        return try decode(AestheticsResponse.self, from: responseData)
    }

    func keypoints(image: CGImage) async throws -> KeypointResult {
        let data = try jpegData(from: image)
        let responseData = try await postMultipart(endpoint: "keypoints", imageData: data)
        let wrapper = try decode(KeypointResponseWrapper.self, from: responseData)
        return wrapper.keypoints
    }

    func flight(image: CGImage) async throws -> FlightResult {
        let data = try jpegData(from: image)
        let responseData = try await postMultipart(endpoint: "flight", imageData: data)
        return try decode(FlightResult.self, from: responseData)
    }

    func identify(image: CGImage, topK: Int = 5, temperature: Float = 1.0) async throws -> [SpeciesMatch] {
        let data = try jpegData(from: image)
        let responseData = try await postMultipart(
            endpoint: "identify?top_k=\(topK)&temperature=\(temperature)",
            imageData: data
        )
        let response = try decode(IdentifyResponse.self, from: responseData)
        return response.species
    }

    func healthCheck() async throws -> ServerHealth {
        let url = baseURL.appendingPathComponent("health")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw InferenceError.serverNotReady
        }
        return try decode(ServerHealth.self, from: data)
    }

    private func postMultipart(endpoint: String, imageData: Data) async throws -> Data {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw InferenceError.requestFailed(statusCode: code)
        }
        return data
    }

    private func jpegData(from image: CGImage, quality: Float = 0.9) throws -> Data {
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw InferenceError.imageConversionFailed
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw InferenceError.imageConversionFailed
        }
        return mutableData as Data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw InferenceError.decodingFailed(underlying: error)
        }
    }
}

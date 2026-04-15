// ModelManifest.swift
//
// The manifest of model files the app needs. Bundled in the app at build
// time (covered by the code signature), lists every downloadable artifact
// with SHA-256 for integrity verification.

import Foundation

public struct ModelManifest: Codable, Sendable {
    public let version: Int
    public let models: [ModelEntry]

    public init(version: Int, models: [ModelEntry]) {
        self.version = version
        self.models = models
    }

    public enum LoadError: Error, CustomStringConvertible {
        case resourceNotFound
        case readFailed(underlying: Error)
        case decodingFailed(underlying: Error)

        public var description: String {
            switch self {
            case .resourceNotFound:
                return "manifest.json not found in SuperPickyInference bundle resources"
            case .readFailed(let underlying):
                return "manifest.json could not be read: \(underlying)"
            case .decodingFailed(let underlying):
                return "manifest.json failed to decode: \(underlying)"
            }
        }
    }

    /// Loads the bundled manifest.json from the SuperPickyInference module bundle.
    /// Throws `LoadError.resourceNotFound` if the resource is missing (build config issue),
    /// `LoadError.readFailed` if the file cannot be read, or
    /// `LoadError.decodingFailed` if the JSON is malformed.
    public static func loadBundled() throws -> ModelManifest {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BundleAnchor.self)
        #endif
        guard let url = bundle.url(forResource: "manifest", withExtension: "json") else {
            throw LoadError.resourceNotFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.readFailed(underlying: error)
        }
        do {
            return try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw LoadError.decodingFailed(underlying: error)
        }
    }
}

/// Anchor class used by `Bundle(for:)` to locate the framework's resource
/// bundle when built via xcodebuild (as a proper framework target). SPM
/// builds use `Bundle.module` instead.
private final class BundleAnchor {}

public struct ModelEntry: Codable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let url: URL
    public let sha256: String
    public let sizeBytes: Int64
    public let installPath: String

    public init(
        id: String,
        filename: String,
        url: URL,
        sha256: String,
        sizeBytes: Int64,
        installPath: String
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.installPath = installPath
    }
}

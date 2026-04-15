// InferenceBackendSetting.swift
//
// User preference for which InferenceClient implementation to use.
// Phase 0: only .http is selectable in the UI. Phase 1+ enables .native
// once CoreMLInferenceClient exists and ModelManager reports .ready.

import Foundation

enum InferenceBackend: String, CaseIterable, Codable, Hashable, Sendable {
    case http
    case native
}

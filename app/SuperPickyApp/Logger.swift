import Foundation
import os

/// Latency profile for a single species edit. The fields are split into two
/// phases so profiling never conflates the *immediate* optimistic UI work with
/// the *deferred* persistence that runs behind it:
///
/// - Immediate: `expansion`, `stateApply`, `hierarchy`, `immediate` — all of
///   this happens synchronously before the edit method returns and is what the
///   user perceives as latency.
/// - Deferred: `database` (serialized SQLite overlay) and `queuedXMPWrite`
///   (rows handed to the debounced write-behind queue). XMP *file* latency is
///   never recorded here — it is logged separately by the queue on flush so we
///   don't attribute deferred sidecar I/O to the synchronous edit.
struct SpeciesEditProfile: Sendable {
    let operation: String
    let requestedPhotoCount: Int
    let targetPhotoCount: Int
    /// Rows whose assigned species actually changed (drives undo/persistence).
    let changedPhotoCount: Int

    // Immediate (synchronous, before the edit method returns).
    let expansionMilliseconds: Double
    let stateApplyMilliseconds: Double
    let hierarchyMilliseconds: Double
    let immediateMilliseconds: Double

    // Deferred persistence (populated when the serialized SQLite task finishes).
    var persistedPhotoCount: Int = 0
    var databaseMilliseconds: Double = 0
    var queuedXMPWriteCount: Int = 0
    var persistenceFailed: Bool = false

    var summary: String {
        [
            "species_edit",
            "operation=\(operation)",
            "requested=\(requestedPhotoCount)",
            "targets=\(targetPhotoCount)",
            "changed=\(changedPhotoCount)",
            "expand_ms=\(Self.format(expansionMilliseconds))",
            "state_ms=\(Self.format(stateApplyMilliseconds))",
            "hierarchy_ms=\(Self.format(hierarchyMilliseconds))",
            "immediate_ms=\(Self.format(immediateMilliseconds))",
            "persisted=\(persistedPhotoCount)",
            "db_ms=\(Self.format(databaseMilliseconds))",
            "xmp_queued=\(queuedXMPWriteCount)",
            "persist_failed=\(persistenceFailed)",
        ].joined(separator: " ")
    }

    private static func format(_ milliseconds: Double) -> String {
        String(format: "%.1f", milliseconds)
    }
}

enum SpeciesEditProfiler {
    static let logger = Logger(
        subsystem: "com.halfhacked.superpicky",
        category: "SpeciesEdit"
    )
    static let signposter = OSSignposter(
        subsystem: "com.halfhacked.superpicky",
        category: "SpeciesEdit"
    )
    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    static func elapsedMilliseconds(since start: TimeInterval) -> Double {
        (now() - start) * 1_000
    }
}

extension Logger {
    static let pipeline = Logger(subsystem: "com.halfhacked.superpicky", category: "Pipeline")
    static let inference = Logger(subsystem: "com.halfhacked.superpicky", category: "Inference")
    static let database = Logger(subsystem: "com.halfhacked.superpicky", category: "Database")
    static let ui = Logger(subsystem: "com.halfhacked.superpicky", category: "UI")
    static let navigation = Logger(subsystem: "com.halfhacked.superpicky", category: "NavigationState")
}

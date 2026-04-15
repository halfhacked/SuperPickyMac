// ModelManager.swift
//
// Actor that ensures the model files listed in a manifest are present on
// disk. In Phase 0 the happy path is "manifest is empty → state.ready
// immediately." Phase 1+ adds real download, checksum verification, and
// atomic install.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 3 "Model download manager" for the full design.

import Foundation

public actor ModelManager {

    // MARK: - Public state

    public enum State: Sendable {
        case notStarted
        case downloading(progress: Double, currentFile: String)
        case verifying(file: String)
        case installing(file: String)
        case ready
        case failed(Error)
    }

    public private(set) var state: State = .notStarted

    // MARK: - Private state

    private let manifest: ModelManifest
    private let rootDir: URL
    private var observers: [AsyncStream<State>.Continuation] = []

    // MARK: - Init

    public init(manifest: ModelManifest, rootDir: URL) {
        self.manifest = manifest
        self.rootDir = rootDir
    }

    // MARK: - Public API

    /// Ensures every manifest entry is on disk and verified.
    /// Idempotent — safe to call on every app launch. A second call after
    /// reaching `.ready` is a true no-op: no state transition, no observer
    /// emission.
    ///
    /// Phase 0 behavior: if the manifest is empty, immediately transitions
    /// to `.ready` and emits that state to observers. No network, no disk
    /// writes. Phase 1+ will add real download/verify/install.
    public func ensureReady() async throws {
        if case .ready = state {
            return
        }
        if manifest.models.isEmpty {
            setState(.ready)
            return
        }

        // Phase 1+ replaces this fatalError with real download logic.
        // This fatalError is intentional — it makes it impossible to ship
        // Phase 0 with a non-empty manifest without also shipping the
        // download code. The bundled stub manifest has zero entries, so
        // this line is unreachable in Phase 0.
        fatalError("ModelManager cannot download real models until Phase 1")
    }

    /// Returns an `AsyncStream` that emits every state change.
    /// The first emission is always the current state. If the actor is
    /// already in `.ready` when `observe()` is called, the stream emits
    /// `.ready` once and then finishes. Otherwise the stream finishes
    /// when the actor transitions to `.ready`.
    public func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            // Yield current state first so the observer doesn't have to
            // guess what it missed.
            continuation.yield(state)
            // If we're already in the terminal state, finish the stream
            // immediately rather than leaking the continuation into
            // `observers` (which would never receive another yield).
            if case .ready = state {
                continuation.finish()
                return
            }
            observers.append(continuation)
        }
    }

    // MARK: - Private helpers

    private func setState(_ newState: State) {
        state = newState
        for continuation in observers {
            continuation.yield(newState)
        }
        if case .ready = newState {
            // terminate streams after ready so observers don't wait forever
            for continuation in observers {
                continuation.finish()
            }
            observers.removeAll()
        }
    }
}

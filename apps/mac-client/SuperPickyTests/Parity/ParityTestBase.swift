// ParityTestBase.swift
//
// Base class for Gate #1 (per-endpoint parity) and Gate #2 (end-to-end
// rating diff) parity tests. Phase 0 ships this as an empty shell;
// Phase 1+ adds real setUp() that boots both HTTPInferenceClient and
// CoreMLInferenceClient against a pre-staged model cache.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 6 "Parity testing".

import XCTest
@testable import SuperPicky
@testable import SuperPickyInference

/// Base class for all parity tests. No active test methods in Phase 0.
///
/// Phase 1+ implementers: add setUp() that creates:
///   - httpClient: HTTPInferenceClient (against L2 Python server on 18420)
///   - nativeClient: CoreMLInferenceClient (with pre-staged model cache)
///   - fixtureDir: URL pointing at test Parity/Fixtures/
class ParityTestBase: XCTestCase {
    /// Intentionally empty in Phase 0. Keeps the Parity target compiling
    /// so Phase 1 can add its first test without structural changes.
    func test_parityHarnessCompiles() throws {
        // Sentinel test — no assertions. Exists so XCTest doesn't report
        // "no tests ran" which some CI configurations treat as a failure.
        XCTAssertTrue(true, "Parity harness placeholder; real tests start in Phase 1")
    }
}

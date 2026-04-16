#!/bin/bash
set -e

echo "=== L2: Swift Parity Tests ==="
# Gate #1 parity tests (per-endpoint numerical parity against pre-staged CoreML models).
# Phase 0-2: placeholder suite confirms harness compiles; real tests added in Phase 3+.
# See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md Section 6.

cd apps/mac-client
swift test --filter SuperPickyTests/ParityTestBase

echo "=== L2: Parity tests passed ==="

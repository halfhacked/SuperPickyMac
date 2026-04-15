#!/bin/bash
set -e
echo "=== G1: Static Analysis ==="

# Swift: type check (ARM64 only)
(cd apps/mac-client && swift build --arch arm64 2>&1 | tail -5) &
PID_SWIFT=$!

# SwiftLint: catch unlocalized strings
if command -v swiftlint &>/dev/null; then
    (cd apps/mac-client && swiftlint lint --strict 2>&1 | tail -20) &
    PID_SWIFTLINT=$!
else
    echo "SKIP: swiftlint not installed (brew install swiftlint)"
    PID_SWIFTLINT=""
fi

wait $PID_SWIFT || { echo "FAIL: Swift build failed"; exit 1; }
[ -n "$PID_SWIFTLINT" ] && { wait $PID_SWIFTLINT || { echo "FAIL: SwiftLint found unlocalized strings"; exit 1; }; }

echo "=== L1: Unit Tests ==="

# Swift unit tests
(cd apps/mac-client && swift test --arch arm64 2>&1 | tail -10) &
PID_SWIFT_TEST=$!

wait $PID_SWIFT_TEST || { echo "FAIL: Swift tests failed"; exit 1; }

echo "=== Pre-commit passed ==="

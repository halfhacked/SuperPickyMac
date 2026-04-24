#!/bin/bash
set -e
echo "=== G1 Static + L1 Unit ==="

# xcodebuild test implicitly builds, so lint can run in parallel with it.
# Arch is fixed to arm64 via project settings — no flag needed.
(cd apps/mac-client && xcodebuild test \
    -scheme SuperPicky \
    -destination 'platform=macOS' \
    -only-testing:SuperPickyTests \
    2>&1 | tail -10) &
PID_TEST=$!

if command -v swiftlint &>/dev/null; then
    (cd apps/mac-client && swiftlint lint --strict 2>&1 | tail -20) &
    PID_SWIFTLINT=$!
else
    echo "SKIP: swiftlint not installed (brew install swiftlint)"
    PID_SWIFTLINT=""
fi

wait $PID_TEST || { echo "FAIL: xcodebuild test failed"; exit 1; }
[ -n "$PID_SWIFTLINT" ] && { wait $PID_SWIFTLINT || { echo "FAIL: SwiftLint found unlocalized strings"; exit 1; }; }

echo "=== Pre-commit passed ==="

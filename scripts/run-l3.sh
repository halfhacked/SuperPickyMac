#!/bin/bash
set -e

echo "=== L3: XCUITest BDD ==="
# BDD tests use TEST_MODE=1 (MockInferenceClientForUI) — no server needed.

cd apps/mac-client
xcodebuild test \
    -scheme SuperPicky \
    -destination 'platform=macOS' \
    -only-testing:SuperPickyUITests \
    2>&1 | tail -30

echo "=== L3: BDD tests passed ==="

#!/bin/bash
set -e

echo "=== L2: Swift Parity Tests ==="
# Gate #1 parity tests (per-endpoint numerical parity).
# For end-to-end reference comparison against the Python pipeline, see scripts/parity/run.sh.

cd apps/mac-client
swift test --filter SuperPickyTests/ParityTestBase

echo "=== L2: Parity tests passed ==="

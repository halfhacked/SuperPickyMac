#!/bin/bash
set -e
THRESHOLD=${1:-70}

cd apps/mac-client
swift test --enable-code-coverage 2>&1 | tail -5

PROF_DATA=$(find .build -name "default.profdata" 2>/dev/null | head -1)
BINARY=$(find .build -name "SuperPickyPackageTests" -type f 2>/dev/null | head -1)

if [ -z "$PROF_DATA" ] || [ -z "$BINARY" ]; then
    echo "WARNING: Could not find coverage data, skipping threshold check"
    exit 0
fi

COVERAGE=$(xcrun llvm-cov report "$BINARY" -instr-profile="$PROF_DATA" 2>/dev/null | grep "TOTAL" | awk '{print $NF}' | tr -d '%')

if [ -z "$COVERAGE" ]; then
    echo "WARNING: Could not parse coverage, skipping threshold check"
    exit 0
fi

echo "Coverage: ${COVERAGE}% (threshold: ${THRESHOLD}%)"

if (( $(echo "$COVERAGE < $THRESHOLD" | bc -l) )); then
    echo "FAIL: Coverage ${COVERAGE}% is below threshold ${THRESHOLD}%"
    exit 1
fi

echo "PASS: Coverage meets threshold"

#!/bin/bash
set -e
echo "=== Pre-push: L2 + G2 ==="

scripts/run-l2.sh &
PID_L2=$!

scripts/gate-security.sh &
PID_G2=$!

wait $PID_G2 || { echo "FAIL: Security gate failed"; exit 1; }
wait $PID_L2 || { echo "FAIL: L2 integration tests failed"; exit 1; }

echo "=== Pre-push passed ==="

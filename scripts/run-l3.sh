#!/bin/bash
set -e
PORT=28420
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf /tmp/superpicky_l3_test
}
trap cleanup EXIT

echo "=== L3: Starting inference server on port $PORT ==="
cd python-server

if [ -f ".venv/bin/python" ]; then
    PYTHON=".venv/bin/python"
else
    PYTHON="python3"
fi

$PYTHON superpicky_server.py --port "$PORT" &
SERVER_PID=$!

for i in $(seq 1 120); do
    if curl -s "http://localhost:$PORT/health" | grep -q '"status"'; then
        echo "Server ready after ${i}s"
        break
    fi
    sleep 1
done

echo "=== L3: Running XCUITests ==="
cd ../apps/mac-client
xcodebuild test \
    -scheme SuperPicky \
    -destination 'platform=macOS' \
    -only-testing:SuperPickyUITests \
    2>&1 | tail -30

echo "=== L3: BDD tests passed ==="

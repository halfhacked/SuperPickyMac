#!/bin/bash
set -e
PORT=18420
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        echo "Stopping test server (PID $SERVER_PID)..."
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "=== L2: Starting inference server on port $PORT ==="
cd python-server

# Use venv if available
if [ -f ".venv/bin/python" ]; then
    PYTHON=".venv/bin/python"
else
    PYTHON="python3"
fi

$PYTHON superpicky_server.py --port "$PORT" &
SERVER_PID=$!

echo "Waiting for server to load models..."
for i in $(seq 1 120); do
    if curl -s "http://localhost:$PORT/health" | grep -q '"status"'; then
        echo "Server ready after ${i}s"
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "FAIL: Server exited unexpectedly"
        exit 1
    fi
    sleep 1
done

echo "=== L2: Running integration tests ==="
INFERENCE_URL="http://localhost:$PORT" $PYTHON -m pytest tests/test_integration.py -v --tb=short

echo "=== L2: Integration tests passed ==="

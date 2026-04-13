#!/bin/bash
set -e
echo "=== G1: Static Analysis ==="

# Swift: type check
(cd apps/mac-client && swift build 2>&1 | tail -5) &
PID_SWIFT=$!

# Python: flake8 (skip if not installed)
if command -v flake8 &>/dev/null; then
    (cd python-server && flake8 --max-line-length=120 --ignore=E501,W503 superpicky_server.py inference/ 2>&1) &
    PID_PYTHON=$!
else
    echo "SKIP: flake8 not installed"
    PID_PYTHON=""
fi

wait $PID_SWIFT || { echo "FAIL: Swift build failed"; exit 1; }
[ -n "$PID_PYTHON" ] && { wait $PID_PYTHON || { echo "FAIL: Python lint failed"; exit 1; }; }

echo "=== L1: Unit Tests ==="

# Swift unit tests
(cd apps/mac-client && swift test 2>&1 | tail -10) &
PID_SWIFT_TEST=$!

# Python unit tests (mocked)
if [ -d "python-server/.venv" ]; then
    (cd python-server && .venv/bin/python -m pytest tests/test_server.py -v --tb=short 2>&1 | tail -10) &
    PID_PY_TEST=$!
elif command -v pytest &>/dev/null; then
    (cd python-server && pytest tests/test_server.py -v --tb=short 2>&1 | tail -10) &
    PID_PY_TEST=$!
else
    echo "SKIP: pytest not available"
    PID_PY_TEST=""
fi

wait $PID_SWIFT_TEST || { echo "FAIL: Swift tests failed"; exit 1; }
[ -n "$PID_PY_TEST" ] && { wait $PID_PY_TEST || { echo "FAIL: Python tests failed"; exit 1; }; }

echo "=== Pre-commit passed ==="

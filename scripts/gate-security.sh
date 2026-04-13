#!/bin/bash
set -e
echo "=== G2: Security Gate ==="

if command -v gitleaks &>/dev/null; then
    gitleaks detect --source . --no-banner -v
    echo "PASS: No secrets found"
else
    echo "SKIP: gitleaks not installed (brew install gitleaks)"
fi

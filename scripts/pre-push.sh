#!/bin/bash
set -e
echo "=== Pre-push: G2 Security ==="

scripts/gate-security.sh

echo "=== Pre-push passed ==="

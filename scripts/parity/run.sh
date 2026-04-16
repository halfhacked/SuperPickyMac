#!/bin/bash
# scripts/parity/run.sh
#
# End-to-end parity harness: generate the Python reference (if stale) and
# diff it against the Swift .report.db. See scripts/parity/README.md for
# tolerance rationale and usage.
#
# Usage:
#   ./scripts/parity/run.sh [folder]
#
# Default folder is ./real-photos relative to the repo root.

set -eu

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
FOLDER="${1:-$REPO_ROOT/real-photos}"
REF="$FOLDER/.parity-python.json"
DB="$FOLDER/.report.db"
PYTHON="$HOME/projects/SuperPicky/.venv/bin/python"

if [[ ! -x "$PYTHON" ]]; then
    echo "FAIL: missing SuperPicky venv at $PYTHON"
    echo "      create it via: cd ~/projects/SuperPicky && python3 -m venv .venv && .venv/bin/pip install -r requirements.txt"
    exit 2
fi

if [[ ! -d "$FOLDER" ]]; then
    echo "FAIL: folder not found: $FOLDER"
    exit 2
fi

if [[ ! -f "$DB" ]]; then
    echo "FAIL: Swift .report.db not found at $DB"
    echo "      Process $FOLDER through SuperPicky first."
    exit 2
fi

# Regenerate reference if missing OR any model weight is newer.
NEED_REGEN=0
if [[ ! -f "$REF" ]]; then
    NEED_REGEN=1
else
    for W in \
        "$HOME/projects/SuperPicky/models/superFlier_efficientnet.pth" \
        "$HOME/projects/SuperPicky/models/cub200_keypoint_resnet50_slim.pth" \
        "$HOME/projects/SuperPicky/models/model20240824.pth" \
        "$HOME/projects/SuperPicky/models/cfanet_iaa_ava_res50-3cd62bb3.pth" \
        "$HOME/projects/SuperPicky/models/yolo11l-seg.pt"; do
        if [[ -f "$W" && "$W" -nt "$REF" ]]; then
            echo "Reference is older than $W — regenerating."
            NEED_REGEN=1
            break
        fi
    done
fi

if (( NEED_REGEN )); then
    echo "Generating Python reference → $REF"
    "$PYTHON" "$REPO_ROOT/scripts/parity/generate_python_reference.py" \
        --folder "$FOLDER" \
        --output "$REF"
else
    echo "Reusing existing reference: $REF"
fi

echo
python3 "$REPO_ROOT/scripts/parity/diff_python_vs_swift.py" \
    --reference "$REF" \
    --swift-db  "$DB"

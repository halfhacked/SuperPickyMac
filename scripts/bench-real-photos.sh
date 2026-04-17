#!/bin/bash
# Benchmark: process real-photos/ with the full pipeline and measure time.
# Usage: scripts/bench-real-photos.sh [folder]
set -e

FOLDER="${1:-$(cd "$(dirname "$0")/.." && pwd)/real-photos}"

cleanup() {
    pkill -f "SuperPicky" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== Benchmark: $FOLDER ==="
echo "Photos: $(ls "$FOLDER"/*.ARW "$FOLDER"/*.arw "$FOLDER"/*.jpg "$FOLDER"/*.JPG 2>/dev/null | wc -l | tr -d ' ')"
echo "Size:   $(du -sh "$FOLDER" | cut -f1)"

# Remove existing .report.db so we process from scratch
rm -f "$FOLDER/.report.db"

# Build
echo ""
echo "=== Building ==="
cd "$(dirname "$0")/../apps/mac-client"
xcodebuild -scheme SuperPicky -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -1

# Find the built app
APP_PATH="$(find ~/Library/Developer/Xcode/DerivedData/SuperPicky-*/Build/Products/Debug/SuperPicky.app -maxdepth 0 2>/dev/null | head -1)"
if [ -z "$APP_PATH" ]; then
    echo "ERROR: Could not find built app"
    exit 1
fi

# Launch app with TEST_FOLDER
echo ""
echo "=== Processing $FOLDER ==="
START_TIME=$(date +%s)

BINARY="$APP_PATH/Contents/MacOS/SuperPicky"
TEST_FOLDER="$FOLDER" "$BINARY" &
APP_PID=$!

# Wait for .report.db to appear and processing to complete
echo "Waiting for processing to complete..."
DB_PATH="$FOLDER/.report.db"
while [ ! -f "$DB_PATH" ]; do
    sleep 1
done

# Wait for processing to finish. We're done when row count reaches EXPECTED,
# or when there's been no progress for a long time (stall → likely crash).
# Checking for stall on a shorter window falsely fires when DB writes come
# in bursts (concurrent decode + serial post-processing means flat stretches
# happen even under healthy load).
EXPECTED=$(ls "$FOLDER"/*.ARW "$FOLDER"/*.arw "$FOLDER"/*.jpg "$FOLDER"/*.JPG 2>/dev/null | wc -l | tr -d ' ')
PREV_COUNT=0
STALL=0
MAX_STALL=120  # 2 min of zero progress → abort
MAX_TOTAL=1800 # 30 min hard cap
T0=$(date +%s)
while true; do
    sleep 3
    COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM photos;" 2>/dev/null || echo "0")
    NOW=$(date +%s)
    ELAPSED=$((NOW - T0))
    echo "  Processed: $COUNT / $EXPECTED  (${ELAPSED}s)"
    if [ "$COUNT" -ge "$EXPECTED" ]; then
        break
    fi
    if [ "$COUNT" = "$PREV_COUNT" ]; then
        STALL=$((STALL + 3))
    else
        STALL=0
    fi
    PREV_COUNT=$COUNT
    if [ $STALL -ge $MAX_STALL ]; then
        echo "  STALL: no progress for ${STALL}s → aborting"
        break
    fi
    if [ $ELAPSED -ge $MAX_TOTAL ]; then
        echo "  TIMEOUT: ${MAX_TOTAL}s hard cap reached"
        break
    fi
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

# Stats
TOTAL=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM photos;")
BIRDS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM photos WHERE birdConfidence IS NOT NULL;")
SPECIES=$(sqlite3 "$DB_PATH" "SELECT COUNT(DISTINCT speciesCommonName) FROM photos WHERE speciesCommonName IS NOT NULL;")
RATED=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM photos WHERE starRating >= 0;")

echo ""
echo "=== Results ==="
echo "Total time:  ${ELAPSED}s"
echo "Per photo:   $(echo "scale=2; $ELAPSED / $TOTAL" | bc)s"
echo "Photos:      $TOTAL"
echo "Birds found: $BIRDS"
echo "Species:     $SPECIES"
echo "Rated:       $RATED"
echo ""

# Rating breakdown
echo "Rating breakdown:"
sqlite3 "$DB_PATH" "SELECT starRating, COUNT(*) as count FROM photos GROUP BY starRating ORDER BY starRating DESC;"

echo ""
echo "Species breakdown:"
sqlite3 "$DB_PATH" "SELECT speciesCommonName, COUNT(*) as count FROM photos WHERE speciesCommonName IS NOT NULL GROUP BY speciesCommonName ORDER BY count DESC LIMIT 10;"

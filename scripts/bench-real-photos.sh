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

# Wait for processing to finish (check row count stabilizes)
PREV_COUNT=0
STABLE=0
while [ $STABLE -lt 3 ]; do
    sleep 2
    COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM photos;" 2>/dev/null || echo "0")
    EXPECTED=$(ls "$FOLDER"/*.ARW "$FOLDER"/*.arw "$FOLDER"/*.jpg "$FOLDER"/*.JPG 2>/dev/null | wc -l | tr -d ' ')
    echo "  Processed: $COUNT / $EXPECTED"
    if [ "$COUNT" = "$EXPECTED" ]; then
        STABLE=$((STABLE + 1))
    elif [ "$COUNT" = "$PREV_COUNT" ] && [ "$COUNT" -gt 0 ]; then
        STABLE=$((STABLE + 1))
    else
        STABLE=0
    fi
    PREV_COUNT=$COUNT
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

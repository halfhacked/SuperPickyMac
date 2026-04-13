#!/bin/bash
set -e
FIXTURE_DIR="python-server/tests/fixtures"
mkdir -p "$FIXTURE_DIR"

if [ ! -f "$FIXTURE_DIR/test_bird.jpg" ]; then
    echo "Downloading test bird photo (Unsplash CC0)..."
    curl -L -o "$FIXTURE_DIR/test_bird.jpg" \
        "https://images.unsplash.com/photo-1444464666168-49d633b86797?w=800&h=600&fit=crop"
    echo "Downloaded to $FIXTURE_DIR/test_bird.jpg"
else
    echo "Test fixture already exists"
fi

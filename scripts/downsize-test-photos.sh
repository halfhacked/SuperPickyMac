#!/usr/bin/env bash
# Downsize test-photos/*.jpg to 2048 px long edge @ Q60 for fast CI decode.
# Preserves EXIF (shifted dates, Seattle GPS, zeroed serial, sub-second
# burst timing) — none of it is stripped by ImageMagick resize.
#
# Use after re-extracting fixtures from ~/photo (see test-photos/ history)
# or when a new photo is added.

set -euo pipefail

cd "$(dirname "$0")/../test-photos"

for f in *.jpg; do
  magick "$f" -resize '2048x2048>' -quality 60 "/tmp/downsize_$f"
  mv "/tmp/downsize_$f" "$f"
done

echo "Downsized $(ls *.jpg | wc -l | tr -d ' ') JPGs. Total: $(du -sh . | cut -f1)."

# Parity Harness — End-to-End Verification (Next Session)

**Branch:** `claude/inspiring-agnesi`
**Last commit:** `6570f68 feat(parity): close top-5, distribution, bbox, pinyin, GPS-filter gaps`
**Prior plan:** `/Users/dazhen/.claude/plans/majestic-enchanting-pnueli.md`

## Context

The five parity gaps (top-5 species, aesthetics distribution, bbox
IoU, pinyin agreement, GPS/eBird regional filter) were closed in
commit `6570f68`. All 263 unit tests pass. Python reference script
was smoke-tested on two RAW photos — regional filter fires
correctly, bbox/distribution/top-5 are all populated.

**What this session did NOT do:** Run the full harness end-to-end
against a rebuilt Swift binary. The plan verification steps need a
live `.report.db` produced by `SuperPicky.app` with the v5 schema,
which requires:

1. Rebuild the app so it picks up the schema-v5 migration.
2. First-launch download of the 102 MB `avonet.db` from HuggingFace
   (new entry in `manifest.json`).
3. Reprocess `~/projects/SuperPickyMac/real-photos/` (156 photos).
4. Run the diff and check the new metrics against the observed
   baselines.

## Step-by-step verification

```bash
cd ~/projects/SuperPickyMac/.claude/worktrees/inspiring-agnesi/apps/mac-client

# 1. Clean + rebuild so the v5 migration runs on a fresh DB.
rm -rf ~/Library/Application\ Support/com.superpicky.mac/ModelCache/avonet.db*
rm ~/projects/SuperPickyMac/real-photos/.report.db  # force reprocess

xcodebuild test -scheme SuperPicky -destination 'platform=macOS' \
    -only-testing:SuperPickyTests  # should be 263 green (or higher if we add more)

xcodebuild -scheme SuperPicky -configuration Debug \
    -derivedDataPath /tmp/spm-ddata build
open /tmp/spm-ddata/Build/Products/Debug/SuperPicky.app

# 2. Let the app download avonet.db (watch Console.app for progress,
#    or tail ~/Library/Logs/com.superpicky.mac/...). Drag real-photos/
#    onto the window to reprocess. Expect ~5 min for 156 RAW photos.

# 3. Regenerate the Python reference — new shape includes top-5,
#    speciesTop5[], aestheticsDistribution, birdBbox, gps.
~/projects/SuperPicky/.venv/bin/python \
    scripts/parity/generate_python_reference.py \
    --folder ~/projects/SuperPickyMac/real-photos \
    --output ~/projects/SuperPickyMac/real-photos/.parity-python.json

# 4. Diff.
python3 scripts/parity/diff_python_vs_swift.py \
    --reference ~/projects/SuperPickyMac/real-photos/.parity-python.json \
    --swift-db  ~/projects/SuperPickyMac/real-photos/.report.db
```

## Expected results

- **Canonical test photo DSC00166** ("Cepphus grylle" vs "Cepphus
  columba"): this specific photo has NO GPS EXIF. Python reference
  already returns `Cepphus columba` (70.6%) / `Cepphus grylle`
  (28.4%) under the new inline-TTA path. Swift should match once
  the rebuild picks up the new `identify` path. If DSC00166 is
  still `Cepphus grylle` on Swift after rebuild, it's a genuine
  inference divergence, not a filter issue.

- **DSC00050** (Tacoma, WA; lat=47.27, lon=-122.65): Python uses
  `threshold_used="regional"` and returns Barrow's Goldeneye at
  79.7%. Swift should also show regional filtering active for this
  photo (and all other photos with GPS EXIF) after the rebuild.

- **New check thresholds** will need calibration against observed
  numbers on the first full run. The defaults are:
  - Top-5 Jaccard p50 ≥ 0.60
  - Top-1 ∈ other's top-5 ≥ 95%
  - Pinyin agreement ≥ 98% (null==null currently)
  - Distribution L1 p95 < 0.30
  - Bbox IoU p50 ≥ 0.80, p5(worst) ≥ 0.60

  If any are too loose/strict, tighten and record the observed
  baseline numbers in `scripts/parity/README.md`.

## Known issue to confirm

The bundled eBird JSON format mismatch (reviewer blocker B1 in the
previous session) was **fixed in commit 6570f68** —
`parseEbirdJSON` now accepts both `{"country_code", "species": []}`
and bare-array shapes. Worth confirming on the first full run that
GPS-tagged photos with a resolvable state (e.g. US-WA) actually
show `thresholdUsed: "regional"` in the Swift DB and not `"global"`.
Query to check after reprocessing:

```bash
sqlite3 ~/projects/SuperPickyMac/real-photos/.report.db \
    "SELECT filename, speciesScientificName, speciesTop5JSON FROM photos LIMIT 3;"
```

Each row's `speciesTop5JSON` should decode to a list with a
`threshold_used` field on each entry.

## If something breaks

- **avonet.db fails to download:** check manifest.json URL + SHA
  (HuggingFace sometimes re-tags files). Raw 107 MB file with
  SHA `6dd77175...` per manifest.
- **eBird JSONs not found at runtime:** check that xcodebuild
  shipped `Resources/ebird/` into the framework bundle. Worth
  spot-checking with `ls /tmp/spm-ddata/Build/Products/Debug/SuperPicky.app/Contents/Frameworks/SuperPickyInference.framework/Versions/A/Resources/ebird/ | wc -l` (should be 145).
- **Swift app can't find avonet.db:** `SpeciesFilter.init` is
  non-throwing when avonet.db is missing — it just returns nil
  from `queryAvonet` and falls through to the eBird JSON cascade.
  If `CoreMLInferenceClient.make()` throws on init, something else
  is wrong.

## Out of scope (confirmed low priority)

- Multi-bird photos (only first detection compared in harness).
- UI toggle for the regional filter (currently implicit — every
  GPS-tagged photo gets filtered).
- Recomputed star ratings when filter changes species → aesthetics
  changes. Covered at folder level by existing Swift tests.

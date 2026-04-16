# Per-Model Parity Harness

Compare the Swift CoreML inference output against the reference Python
pipeline from `~/projects/SuperPicky`. Designed to catch the class of
regression that, in practice, has only been caught by noticing wrong
results in the UI — preprocessing drift between SuperPicky's PyTorch
pipeline and the native Swift rewrite.

## What it checks

For each photo in a folder, runs the full per-photo pipeline through
both sides and diffs the fields that end up in the Swift `.report.db`:

| Model        | Field(s) compared                                                        |
|--------------|--------------------------------------------------------------------------|
| Flight       | `isFlying` decision, `flightConfidence`                                  |
| YOLO / bird  | `birdConfidence` presence agreement, `birdBboxJSON` IoU                  |
| Species      | `speciesScientificName` (top-1), top-5 Jaccard, top-1 ∈ other's top-5    |
| Pinyin       | `speciesPinyin` exact-match rate (both sides currently null — agreement) |
| Keypoints    | `(leftEye, rightEye, beak)` × `(X, Y, Vis)` — 9 fields                   |
| Aesthetics   | `aestheticsScore` (MOS), `aestheticsDistributionJSON` (10-bin L1 delta)  |
| GPS          | Regional OSEA filter exercised end-to-end (Swift SpeciesFilter cascade)  |

The Swift side is read straight from the `.report.db` that
`SuperPicky.app` writes (schema v5+). The Python reference mirrors
`CoreMLInferenceClient.identify` stage-for-stage using the same
models SuperPicky loads from `~/projects/SuperPicky/models/`, and
applies the same Avonet/eBird regional cascade when the photo has
GPS EXIF.

## What it does NOT check

- **Bit-exact numerical parity.** CoreML runs in fp16 on the ANE, and
  the preprocessing paths are not identical at the pixel level
  (slightly different JPEG decoders, bilinear vs Lanczos where
  unavoidable). A few percent of confidence jitter is expected.
- **Multi-bird photos.** Both sides record only the top-confidence
  detection per photo. Photos with two birds in-frame still pass
  through the pipeline, but the diff harness compares a single row.
- **Head sharpness and star rating.** These are derived fields, not
  direct model outputs.

## Usage

```bash
# One-shot run — regenerates Python reference if it's stale, then diffs.
./scripts/parity/run.sh ~/projects/SuperPickyMac/real-photos

# Manual: regenerate reference only (e.g. after swapping a model weight).
~/projects/SuperPicky/.venv/bin/python \
    scripts/parity/generate_python_reference.py \
    --folder ~/projects/SuperPickyMac/real-photos \
    --output ~/projects/SuperPickyMac/real-photos/.parity-python.json

# Manual: diff only (if the reference is fresh).
python3 scripts/parity/diff_python_vs_swift.py \
    --reference ~/projects/SuperPickyMac/real-photos/.parity-python.json \
    --swift-db  ~/projects/SuperPickyMac/real-photos/.report.db
```

The runner exits 0 on all-green, 1 if any model breaches its tolerance,
2 on environment errors (missing venv, missing DB, etc.).

## Observed baseline

Running the harness on 106 photos from `real-photos/` (a 156-photo
RAW set of 26 Bald Eagles including one 11-frame takeoff burst, and
Common Loons on water) on the current `main`:

| Model | Metric | Python | Swift | Δ / Agreement | Tolerance | Status |
|---|---|---|---|---|---|---|
| **Flight** | Photos classified flying | 12/106 (11.3%) | 11/106 (10.4%) | 105/106 agree (**99.1%**) | ≥ 95% | PASS |
| **Flight** | Mean `flightConfidence` (flying) | 0.961 | 0.976 | p95 Δ = **0.161** | < 0.20 | PASS |
| **YOLO** | Birds detected | 104/106 | 104/106 | 2/106 presence disagree (**1.9%**) | < 3% | PASS |
| **YOLO** | Mean `birdConfidence` | 0.888 | 0.897 | p95 Δ = **0.133** | < 0.25 | PASS |
| **Species** | Top-1 matches (both ID'd) | 104 | 104 | 104/104 (**100.0%**) | ≥ 90% | PASS |
| **Species** | Mean `speciesConfidence` on matches | 0.916 | 0.923 | p95 Δ = **0.063** | < 0.20 | PASS |
| **Keypoints** | Mean `rightEyeVis` | 0.884 | 0.862 | coord p95 Δ = **0.040** | < 0.08 | PASS |
| **Keypoints** | Mean `beakVis` | 0.957 | 0.953 | vis p95 Δ = **0.039** | < 0.15 | PASS |
| **Aesthetics** | Mean MOS | 4.95 | 4.92 | p50/p95/max = 0.04 / **0.11** / **0.15** | p95 < 0.5, max < 1.0 | PASS |

Species top-1 distribution (same on both sides): Common Loon 78,
Bald Eagle 26, none 2. Left-eye visibility is low on both sides
(Python 0.048, Swift 0.037) because most photos in the set show
profile views of the bird where only the right eye is visible.

### Extended parity checks (schema v5)

After the v5 migration added `speciesTop5JSON`,
`aestheticsDistributionJSON`, and `birdBboxJSON` columns, four new
per-run metrics catch drift that was previously invisible:

| Check | What it measures | Threshold |
|---|---|---|
| **Top-5 Jaccard** | `\|py_top5 ∩ sw_top5\| / \|py_top5 ∪ sw_top5\|` per photo, reported p50 + p5(worst) | p50 ≥ 0.60 |
| **Top-1 inclusion** | "Each side's top-1 is somewhere in the other's top-5" | ≥ 95% both directions |
| **Pinyin agreement** | Exact-string match on `speciesPinyin` when both sides have a Chinese name (currently null==null) | ≥ 98% |
| **Aesthetics distribution L1** | `Σ\|py[i] − sw[i]\|` across 10 AVA bins (bounded by 2) | p95 < 0.30, max < 0.50 |
| **YOLO bbox IoU** | Intersection-over-union on the top-confidence detection's normalized rectangle | p50 ≥ 0.80, p5(worst) ≥ 0.60 |

The GPS/eBird regional filter is exercised end-to-end: photos with
GPS EXIF get the same Avonet/eBird cascade on both sides, and
species disagreements that used to stem from Swift's unfiltered
global softmax now hit the same masked softmax the Python reference
uses. The harness surfaces genuine model drift, not missing-filter
artefacts.

Tolerances live in `diff_python_vs_swift.py` as constants. Adjust
based on observed deltas — the rule of thumb is: catch regressions
wider than fp16 jitter, don't fail on it. When loosening, record
the observed p50/p95/max so a future reader knows why the number
was chosen.

## When to run

- **After any change to a model file** (new `.mlpackage`, re-conversion).
- **After any change to preprocessing** — either `PipelineCoordinator`
  or any of the CoreML wrappers in
  `apps/mac-client/SuperPickyInference/Models/`.
- **After any `InferenceClient` contract change**.
- **Before shipping a release.**

Explicitly **not** wired into pre-commit or pre-push — the run takes
~5 minutes on real-photos (150 photos × ~2 s each for the Python
pipeline) and requires the SuperPicky venv, which is a heavy dep not
every developer will have set up.

## Requirements

- `~/projects/SuperPicky/.venv` — full PyTorch / ultralytics / PIL
  install. Set up via the SuperPicky repo's own `requirements.txt`.
- The Swift app must have already processed the target folder (so
  `.report.db` exists with populated photo rows).
- Model weights at `~/projects/SuperPicky/models/` — same set used
  when converting CoreML models via `scripts/convert_*.py`.

## Adding fixtures

Any folder of JPEG / RAW photos works. The harness doesn't require a
specific set — it processes whatever's in the folder and compares the
intersection with the Swift DB. To add more coverage, drop photos
into the target folder, re-run Swift processing (the app's Reprocess
context menu), and re-run the harness. The reference will regenerate
automatically on the next run.

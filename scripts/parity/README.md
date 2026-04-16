# Per-Model Parity Harness

Compare the Swift CoreML inference output against the reference Python
pipeline from `~/projects/SuperPicky`. Designed to catch the class of
regression that, in practice, has only been caught by noticing wrong
results in the UI — preprocessing drift between SuperPicky's PyTorch
pipeline and the native Swift rewrite.

## What it checks

For each photo in a folder, runs the full per-photo pipeline through
both sides and diffs the fields that end up in the Swift `.report.db`:

| Model        | Field(s) compared                                               |
|--------------|-----------------------------------------------------------------|
| Flight       | `isFlying` decision, `flightConfidence`                         |
| YOLO / bird  | `birdConfidence` (detection count and presence agreement)       |
| Species      | `speciesScientificName` (top-1), `speciesConfidence`            |
| Keypoints    | `(leftEye, rightEye, beak)` × `(X, Y, Vis)` — 9 fields          |
| Aesthetics   | `aestheticsScore` (MOS in [1, 10])                              |

The Swift side is read straight from the `.report.db` that
`SuperPicky.app` writes. The Python reference mirrors
`PipelineCoordinator.runAnalysis` stage-for-stage using the same
models SuperPicky loads from `~/projects/SuperPicky/models/`.

## What it does NOT check

- **Bit-exact numerical parity.** CoreML runs in fp16 on the ANE, and
  the preprocessing paths are not identical at the pixel level
  (slightly different JPEG decoders, bilinear vs Lanczos where
  unavoidable). A few percent of confidence jitter is expected.
- **YOLO bounding box coordinates.** The Swift `.report.db` schema
  dropped `birdBbox` / `birdMask` in migration v3. Bbox drift is
  detected indirectly because it propagates to every downstream
  model (wrong crop → wrong flight/species confidence).
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

Running the harness on `real-photos/` (93 of a 156-photo RAW set —
26 Bald Eagles on poles including one 11-frame takeoff burst, and
65 Common Loons on water) on the current `main`:

### Flight (EfficientNet-B3 binary classifier)

| Metric                              | Python     | Swift      | Δ / match         |
|-------------------------------------|------------|------------|-------------------|
| Photos classified as flying         | 12/93 (13%)| 11/93 (12%)| —                 |
| Mean `flightConfidence` (all)       | 0.168      | 0.204      | —                 |
| Mean `flightConfidence` (flying)    | 0.961      | 0.976      | —                 |
| Decision agreement                  | —          | —          | 92/93 (98.9%)     |
| Confidence Δ on matching decisions  | —          | —          | p95 = 0.167       |

### YOLO (yolo11l-seg, COCO class 14 = bird)

| Metric                     | Python   | Swift    | Δ / match                |
|----------------------------|----------|----------|--------------------------|
| Birds detected             | 91/93    | 91/93    | presence disagree 2/93   |
| Mean `birdConfidence`      | 0.885    | 0.895    | p95 Δ = 0.135            |

### Species (OSEA ResNet34, 10 964 classes)

| Metric                              | Python | Swift | Δ / match      |
|-------------------------------------|--------|-------|----------------|
| Top-1 species = "Common Loon"       | 65     | 65    | —              |
| Top-1 species = "Bald Eagle"        | 26     | 26    | —              |
| Top-1 species = none (YOLO miss)    | 2      | 2     | —              |
| Top-1 agreement (both identified)   | —      | —     | 91/91 (100.0%) |
| Mean `speciesConfidence` on matches | 0.916  | 0.921 | p95 Δ = 0.119  |

### Keypoints (ResNet50 PartLocalizer)

| Metric                           | Python | Swift | Δ / match                    |
|----------------------------------|--------|-------|------------------------------|
| Mean `leftEyeVis`                | 0.055  | 0.043 | —                            |
| Mean `rightEyeVis`               | 0.869  | 0.844 | —                            |
| Mean `beakVis`                   | 0.952  | 0.948 | —                            |
| Coord Δ (x, y across 6 values)   | —      | —     | p95 = 0.043, max = 0.138     |
| Visibility Δ                     | —      | —     | p95 = 0.050                  |

(`leftEyeVis` is low because most photos in the test set show a
profile view of the bird with only the right eye visible — the mean
is dominated by the low values for the hidden-side eye.)

### Aesthetics (CFANet / TOPIQ)

| Metric     | Python | Swift | Δ / match                           |
|------------|--------|-------|-------------------------------------|
| Mean MOS   | 4.98   | 4.95  | —                                   |
| MOS Δ      | —      | —     | p50 = 0.04, p95 = 0.12, max = 0.15  |

## Tolerances

| Model      | Primary metric                                  | Tolerance              |
|------------|--------------------------------------------------|------------------------|
| Flight     | `isFlying` decision agreement                    | ≥ 95 %                 |
| Flight     | `flightConfidence` Δ on matching decisions (p95) | < 0.20                 |
| YOLO       | presence disagreement (one side found a bird)    | < 3 %                  |
| YOLO       | `birdConfidence` Δ (p95)                          | < 0.25                 |
| Species    | Top-1 `speciesScientificName` exact match        | ≥ 90 %                 |
| Species    | `speciesConfidence` Δ on matches (p95)           | < 0.20                 |
| Keypoints  | Any (x, y) coord Δ (p95)                          | < 0.08                 |
| Keypoints  | Visibility Δ (p95)                                | < 0.15                 |
| Aesthetics | MOS Δ (p95) / (max)                               | < 0.5 / < 1.0          |

Tolerances live in `diff_python_vs_swift.py` as constants. Adjust based
on observed deltas — the rule of thumb is: catch regressions wider
than fp16 jitter, don't fail on it. When loosening, record the
observed p50/p95/max so a future reader knows why the number was
chosen.

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

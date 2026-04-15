# Port superpicky Algorithms to SuperPickyMac

> Bring SuperPickyMac's rating pipeline to feature parity with superpicky's Python implementation. Every algorithm, threshold, and edge case from superpicky must be faithfully ported — no simplified stubs.

## Status

| # | Commit | Description | Status |
|---|--------|-------------|--------|
| 1 | `docs: add algorithm parity plan` | This plan | done |
| 2 | `test: add Tenengrad + HeadSharpness tests (TDD)` | Sharpness algorithm tests | pending |
| 3 | `feat: port Tenengrad sharpness with masked head region` | Replace eye-visibility proxy | pending |
| 4 | `test: add RatingEngine parity tests (TDD)` | Focus weights, visibility, thresholds | pending |
| 5 | `feat: port RatingEngine with visibility + focus weights` | Full algorithm port | pending |
| 6 | `feat: port ISO normalization` | EXIF ISO read + sharpness factor | pending |
| 7 | `feat: port focus point detection` | Multi-brand EXIF AF parsing + 4-tier weights | pending |
| 8 | `test: add advanced config tests (TDD)` | Skill level presets, all params | pending |
| 9 | `feat: port advanced config parameters` | CullingConfig parity | pending |
| 10 | `feat: port picked flag calculation` | Top sharpness ∩ aesthetics marking | pending |
| 11 | `feat: port burst pHash verification` | Perceptual hash similarity check | pending |
| 12 | `test: integration test with real photos` | Verify scores match installed app | pending |

---

## Background

SuperPickyMac's culling pipeline diverged from superpicky's Python implementation. Key gaps:

1. **Sharpness**: Was `bestEyeVisibility × 600` (a proxy), not real pixel sharpness. Tenengrad was added this session but needs head-region masking.
2. **Rating engine**: Missing eye visibility weighting, focus point weighting, and correct minimum aesthetics (3.5 vs 2.0).
3. **ISO normalization**: High-ISO noise inflates sharpness scores — superpicky compensates, Mac doesn't.
4. **Focus point detection**: superpicky reads AF data from RAW EXIF (Nikon/Sony/Canon/Olympus/Fuji/Panasonic) and adjusts ratings. Mac has no equivalent.
5. **Advanced config**: superpicky has 25+ configurable parameters; Mac has 3.
6. **Picked flag**: superpicky marks top sharpness ∩ aesthetics photos. Mac doesn't.
7. **Burst pHash**: superpicky verifies burst groups with perceptual hash similarity. Mac uses timestamp only.

### What's already done in this session

- `TenengradSharpness.score()` — Sobel gradient + log normalization (0-1000 scale) ✓
- `TenengradSharpness.maskedScore()` — circular mask variant ✓
- `HeadSharpness.score()` — eye-centered circular mask with beak distance radius ✓
- `RatingEngine` — visibility weighting + focus weight params + reason strings ✓
- `PipelineCoordinator` — ISO normalization + HeadSharpness + focus weight wiring ✓
- `FocusPointDetector` — basic ImageIO stub (needs proper multi-brand implementation) ⚠️
- Minimum aesthetics updated to 3.5 ✓

---

## Delivery Goal

**Setup:**
```bash
cd apps/mac-client && swift build
```

**Run:**
```bash
# Process real photos and compare scores
pkill -f SuperPicky 2>/dev/null
rm -f /path/to/real-photos/.report.db
TEST_FOLDER=/path/to/real-photos .build/xcode/Build/Products/Debug/SuperPicky.app/Contents/MacOS/SuperPicky
```

**Verify:**
1. `swift test` — all tests pass
2. Eagle photos (DSC00001-00009) get sharpness scores in the 400-600 range (head-region Tenengrad, not 590 eye-visibility proxy)
3. Distant/blurry birds get noticeably lower sharpness than close-up sharp birds
4. High-ISO photos get reduced sharpness (ISO 6400 → ~15% lower than ISO 800)
5. Photos with visible eyes get higher ratings than those with hidden eyes (visibility weighting)
6. Scores are different from the old `bestEyeVisibility × 600` formula — proving real pixel sharpness is being measured

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Sharpness algorithm | Tenengrad (Sobel gradient magnitude) | Matches superpicky; more robust to noise than Laplacian |
| Sharpness normalization | Log scale, MIN_VAL=100, MAX_VAL=154016, range 0-1000 | Exact match of superpicky's calibration |
| Head region mask | Circular mask at eye, radius = eye-beak distance × 1.2 | Matches superpicky's `_calculate_head_sharpness` |
| Visibility weighting | `max(0.5, min(1.0, bestEyeVisibility × 2))` | Exact match of superpicky's formula |
| Focus point detection | ImageIO MakerNote + SubjectArea parsing | Native macOS, no exiftool dependency; covers Sony ARW (SubjectArea) |
| ISO normalization | 5% penalty per ISO doubling above 800, floor at 0.5 | Exact match of superpicky's `_get_iso_sharpness_factor` |
| Minimum aesthetics | 3.5 | Matches superpicky's `min_nima` |
| Default sharpness threshold | 400 | Matches superpicky's default |
| Rating scale | 0-5 stars (Mac's existing scale) | superpicky uses -1 to 3; Mac maps differently but covers the same logic |

---

## Technical Design

### Key Algorithms (exact formulas from superpicky)

#### 1. Tenengrad Sharpness (keypoint_detector.py lines 313-355)

```
Input: grayscale image + binary mask
gx = Sobel(gray, ksize=3, dx=1, dy=0)
gy = Sobel(gray, ksize=3, dx=0, dy=1)
gradient_magnitude = gx² + gy²
raw_sharpness = mean(gradient_magnitude[mask > 0])

Log normalization:
  MIN_VAL = 100.0
  MAX_VAL = 154016.0
  if raw <= MIN_VAL → 0
  if raw >= MAX_VAL → 1000
  else → (log(raw) - log(MIN_VAL)) / (log(MAX_VAL) - log(MIN_VAL)) × 1000
```

#### 2. Head Region Mask (keypoint_detector.py lines 219-311)

```
Constants:
  VISIBILITY_THRESHOLD = 0.3
  RADIUS_MULTIPLIER = 1.2
  NO_BEAK_RADIUS_RATIO = 0.15
  LOW_VIS_PENALTY = 0.8

Eye selection:
  If both hidden (< 0.3): use higher-visibility eye → apply 0.8x penalty
  If both visible: pick eye farther from beak
  If one visible: use that one

Radius calculation:
  If beak visible: radius = distance(eye, beak) × 1.2
  Else if bbox available: radius = max(bbox_w, bbox_h) × 0.15
  Else: radius = max(crop_w, crop_h) × 0.15
  Clamp: max(10, min(radius, min(w, h) / 2))

Mask: circular at eye position with computed radius
If seg_mask available: intersection(circle, seg_mask)
Compute Tenengrad on masked pixels
```

#### 3. ISO Sharpness Factor (photo_processor.py lines 455-474)

```
ISO_BASE = 800
ISO_PENALTY_FACTOR = 0.05
ISO_MIN_FACTOR = 0.5

if iso <= 800 → factor = 1.0
else → penalty = 0.05 × log₂(iso / 800)
       factor = max(0.5, 1.0 - penalty)

Examples: ISO 800→1.0, 1600→0.95, 3200→0.90, 6400→0.85
```

#### 4. Rating Engine (rating_engine.py lines 101-271)

```
Early exits (must match Python order):
  !detected → 0
  confidence < 0.5 → 0
  all_keypoints_hidden → 1  ← BEFORE sharpness check (Python order)
  sharpness < 100 → 0
  aesthetics < 3.5 → 0

Focus + flying adjustments:
  adj_sharpness = sharpness × focus_sharpness_weight
  adj_aesthetics = aesthetics × focus_aesthetics_weight
  if flying: adj_sharpness ×= 1.2, adj_aesthetics ×= 1.1

Mac's 5-tier rating (extending superpicky's 3-tier):
  moderate_sharpness = (100 + threshold) / 2
  moderate_aesthetics = (3.5 + threshold) / 2

  Both above threshold → 5
  One above threshold + both above moderate → 4
  Both above moderate → 3
  One above moderate → 2
  Neither → 1

Visibility weighting:
  weight = max(0.5, min(1.0, best_eye_visibility × 2))
  rating = round(rating × weight)

Exposure penalty:
  if overexposed or underexposed: rating = max(0, rating - 1)
```

#### 5. Focus Point Weights (focus_point_detector.py lines 792-856)

```
4-layer detection:
  Layer 1 (head circle): sharpness=1.1, aesthetics=1.0
  Layer 2 (SEG mask):    sharpness=0.9, aesthetics=1.0  [Mac: same as bbox since no seg mask]
  Layer 3 (BBox):        sharpness=0.8, aesthetics=0.9
  Layer 4 (outside):     sharpness=0.5, aesthetics=0.8
  Unfocused:             sharpness=0.8, aesthetics=0.9
  No data:               sharpness=1.0, aesthetics=1.0
```

Mac receives seg masks from preen's YOLO seg model when available. Full 4-layer detection:
- Focus in head circle → (1.1, 1.0)
- Focus in seg mask (not head) → (0.9, 1.0)
- Focus in bbox (not seg) → (0.8, 0.9)
- Focus outside bbox → (0.5, 0.8)
- Unfocused → (0.8, 0.9)
- No focus data → (1.0, 1.0)
- When seg mask unavailable: Layer 2 collapses into Layer 3 (bbox)

#### 6. Picked Flag (photo_processor.py lines 2615-2663)

```
1. Filter to highest-rated photos only (5-star in Mac's scale)
2. top_count = max(1, int(count × picked_top_percentage / 100))
3. Sort by aesthetics desc → top N → aesthetics_top
4. Sort by sharpness desc → top N → sharpness_top
5. picked = aesthetics_top ∩ sharpness_top
```

#### 7. Burst pHash Verification (burst_detector.py)

```
Constants:
  PHASH_THRESHOLD = 12 (hamming distance)
  MIN_BURST_COUNT = 4

After timestamp-based grouping:
  For each pair in group: compute pHash of thumbnail
  If hamming_distance(hash_a, hash_b) > 12: split group at that point
```

### Advanced Config Parameters to Add

| Parameter | Type | Default | superpicky equivalent |
|-----------|------|---------|----------------------|
| `minConfidence` | Float | 0.5 | `min_confidence` |
| `minAesthetics` | Float | 3.5 | `min_nima` |
| `pickedTopPercentage` | Int | 25 | `picked_top_percentage` |
| `burstFps` | Int | 10 | `burst_fps` |
| `burstMinCount` | Int | 4 | `burst_min_count` |
| `birdIdConfidence` | Int | 70 | `birdid_confidence` |
| `skillLevel` | enum | intermediate | `skill_level` |

Skill level presets:

| Level | Sharpness | Aesthetics |
|-------|-----------|------------|
| beginner | 300 | 4.5 |
| intermediate | 380 | 4.8 |
| master | 520 | 5.5 |
| custom | user-defined | user-defined |

---

## Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Both eyes invisible | Use higher-vis eye with 0.8x penalty; score may be 0 if gradient too low |
| No beak visible | Head radius = 15% of max(crop_w, crop_h) |
| Crop smaller than min radius (10px) | Return nil → fallback to full-crop Tenengrad |
| ISO not in EXIF | Factor = 1.0 (no penalty) |
| ISO 100 | Factor = 1.0 (below base) |
| No focus data in EXIF | Weights = (1.0, 1.0) — no penalty |
| Manual focus mode | Weights = (1.0, 1.0) — no penalty |
| Focus outside image bounds | Treat as outside bbox → (0.5, 0.8) |
| All 5-star photos identical sharpness | All get picked flag |
| Fewer 5-star photos than top_count | All 5-star photos get picked |
| pHash comparison of very different-sized images | Resize both to 8x8 before hashing |

---

## File Inventory

### Files Changed

| # | File | Op | Description |
|---|------|----|-------------|
| 1 | `SuperPickyApp/LaplacianSharpness.swift` | modify | Already renamed to TenengradSharpness; add maskedScore |
| 2 | `SuperPickyApp/EyeCropSharpness.swift` | modify | Already rewritten as HeadSharpness |
| 3 | `SuperPickyApp/RatingEngine.swift` | modify | Add focus weights, visibility weighting, min aesthetics 3.5 |
| 4 | `SuperPickyApp/PipelineCoordinator.swift` | modify | Wire HeadSharpness, ISO, focus weights |
| 5 | `SuperPickyApp/CullingConfig.swift` | modify | Remove eyeSharpnessThreshold, add new config params |
| 6 | `SuperPickyApp/FocusPointDetector.swift` | modify | Fix weight values, add multi-brand EXIF AF parsing, add unfocused detection |
| 7 | `SuperPickyApp/AdvancedTab.swift` | modify | Remove eye threshold slider, add new config UI |
| 8 | `SuperPickyApp/ThresholdCalibratorView.swift` | modify | Remove eye slider, update Config init |
| 9 | `SuperPickyApp/MainView.swift` | modify | Update RatingEngine.Config init |
| 10 | `SuperPickyApp/PreviewView.swift` | modify | Remove eye sharpness display |
| 11 | `SuperPickyApp/BurstDetector.swift` | modify | Add pHash verification |
| 12 | `SuperPickyApp/AppState.swift` | modify | Add picked flag calculation after processing |
| 13 | `SuperPickyApp/Photo.swift` | modify | Remove eyeSharpnessScore field (unused) |
| 14 | `SuperPickyTests/Core/LaplacianSharpnessTests.swift` | modify | Tests for Tenengrad + maskedScore |
| 15 | `SuperPickyTests/Core/EyeCropSharpnessTests.swift` | modify | Tests for HeadSharpness |
| 16 | `SuperPickyTests/Core/RatingEngineTests.swift` | modify | Tests for visibility + focus weights |

### Files NOT Changed

| File | Reason |
|------|--------|
| `python-server/*` | All changes are client-side Swift |
| `SuperPickyApp/ExposureDetector.swift` | Exposure detection already matches |
| `SuperPickyApp/ExportService.swift` | Export logic unchanged |

---

## Test Plan

### L1 — Unit Tests

| # | Test | What It Validates |
|---|------|-------------------|
| 1 | `TenengradSharpness: solid color → 0` | Zero gradient = zero score |
| 2 | `TenengradSharpness: sharp edges > 100` | High-frequency content scores high |
| 3 | `TenengradSharpness: score capped at 1000` | Upper bound enforced |
| 4 | `TenengradSharpness: maskedScore inside circle only` | Pixels outside mask excluded |
| 5 | `HeadSharpness: both eyes hidden → penalized score` | 0.8x penalty applied |
| 6 | `HeadSharpness: picks eye farther from beak` | Correct eye selection |
| 7 | `HeadSharpness: no beak → 15% radius fallback` | Fallback radius |
| 8 | `HeadSharpness: tiny crop → nil` | Guard against too-small images |
| 9 | `RatingEngine: visibility 0.5 → weight 1.0` | No downgrade for visible eyes |
| 10 | `RatingEngine: visibility 0.25 → weight 0.5` | Progressive downgrade |
| 11 | `RatingEngine: focus head → sharpness 1.1x` | Head focus bonus |
| 12 | `RatingEngine: focus outside → sharpness 0.5x` | Miss penalty |
| 13 | `RatingEngine: min aesthetics 3.5 gate` | Below 3.5 → 0 stars |
| 14 | `ISO factor: ISO 800 → 1.0` | No penalty at base |
| 15 | `ISO factor: ISO 1600 → 0.95` | 5% per doubling |
| 16 | `ISO factor: ISO 6400 → 0.85` | Correct decay |
| 17 | `ISO factor: extreme ISO → floor 0.5` | Hard floor |

### L2 — Integration

| # | Test | What It Validates |
|---|------|-------------------|
| 1 | `Process real-photos and verify score distribution` | Sharp eagles > 400, blurry birds < 200 |
| 2 | `Scores differ from old eyeVisibility×600` | Real sharpness, not proxy |

---

## Tasks

### Task 1: Tenengrad + HeadSharpness (sharpness algorithm)

Port full-crop and masked Tenengrad sharpness from superpicky. Already partially done — needs test verification and edge case fixes.

**Acceptance criteria:**
- [ ] `TenengradSharpness.score()` produces 0-1000 scores with log normalization matching superpicky's MIN_VAL=100, MAX_VAL=154016
- [ ] `TenengradSharpness.maskedScore()` computes Sobel only within a circular mask
- [ ] `HeadSharpness.score()` selects correct eye (farther from beak when both visible)
- [ ] 0.8x penalty when both eyes below visibility 0.3
- [ ] Radius = eye-beak distance × 1.2 when beak visible, 15% fallback otherwise
- [ ] When seg mask is available, intersect circle mask with seg mask before computing Tenengrad
- [ ] All sharpness unit tests pass

### Task 2: RatingEngine parity

Port visibility weighting, focus weight parameters, correct thresholds. Already partially done — needs tests for new behavior.

**Acceptance criteria:**
- [ ] `visibility_weight = max(0.5, min(1.0, bestEyeVisibility × 2))` applied to base rating
- [ ] Focus weights applied before flying bonus (superpicky order)
- [ ] Early exit order matches Python: detected → confidence → allKeypointsHidden → sharpness → aesthetics
- [ ] Minimum aesthetics = 3.5 (was 2.0)
- [ ] Reason string includes focus/visibility/exposure/flying info
- [ ] All rating tests pass with updated thresholds

### Task 3: ISO normalization

Read ISO from EXIF and apply sharpness penalty for high ISO.

**Acceptance criteria:**
- [ ] ISO read from RAW EXIF via `EXIFReader`
- [ ] Factor formula: `max(0.5, 1.0 - 0.05 × log₂(iso / 800))`
- [ ] Applied to sharpness before rating
- [ ] No penalty when ISO unavailable or ≤ 800
- [ ] Unit tests for factor calculation

### Task 4: Focus point detection

Read AF data from RAW EXIF (Sony SubjectArea, Nikon AFAreaXPosition, Canon) and compute 4-tier weights.

**Acceptance criteria:**
- [ ] Reads focus point from Sony ARW (SubjectArea EXIF field)
- [ ] Computes normalized (0-1) focus coordinates
- [ ] Correct weight values: head=(1.1, 1.0), seg=(0.9, 1.0), bbox=(0.8, 0.9), outside=(0.5, 0.8), unfocused=(0.8, 0.9), unknown=(1.0, 1.0)
- [ ] Remove nonexistent "birdFocus" tier from current code
- [ ] Unfocused detection: when EXIF indicates AF attempted but didn't lock → (0.8, 0.9)
- [ ] Seg mask intersection when available from preen's YOLO seg model
- [ ] Default (1.0, 1.0) when no focus data available
- [ ] Wired into PipelineCoordinator → RatingEngine

### Task 5: Advanced config parameters

Add all missing config parameters matching superpicky's `advanced_config.py`.

**Acceptance criteria:**
- [ ] Skill level presets (beginner/intermediate/master/custom) with correct thresholds
- [ ] All parameters from superpicky's config have equivalents in CullingConfig
- [ ] Settings UI updated with new controls
- [ ] Localized strings for all new labels

### Task 6: Picked flag calculation

Mark top photos by intersection of sharpness and aesthetics rankings.

**Acceptance criteria:**
- [ ] After processing, compute picked flag for photos with starRating == 5 (Mac's highest tier, equivalent to Python's 3-star)
- [ ] `picked = top_N_by_aesthetics ∩ top_N_by_sharpness` (default N=25%)
- [ ] Written to Photo.isPick in database
- [ ] Configurable `pickedTopPercentage`

### Task 7: Burst pHash verification

Add perceptual hash comparison to verify burst groups.

**Acceptance criteria:**
- [ ] Check if existing BurstDetector already uses VNFeaturePrintObservation — if so, tune threshold to match superpicky's pHash behavior (hamming ≤ 12 equivalent). If not, add DCT-based pHash (8x8) with hamming distance threshold 12.
- [ ] Split burst group when consecutive photos exceed similarity threshold
- [ ] Only affects burst detection, not rating
- [ ] Configurable threshold

---

## Commit Sequence

| # | Task | Type | Message | Depends On |
|---|------|------|---------|------------|
| 1 | — | docs | `docs: add algorithm parity plan` | — |
| 2 | 1 | test | `test: add Tenengrad + HeadSharpness tests (TDD)` | 1 |
| 3 | 1 | feat | `feat: port Tenengrad sharpness with masked head region` | 2 |
| 4 | 2 | test | `test: add RatingEngine parity tests (TDD)` | 3 |
| 5 | 2 | feat | `feat: port RatingEngine with visibility + focus weights` | 4 |
| 6 | 3 | test | `test: add ISO normalization tests (TDD)` | 5 |
| 7 | 3 | feat | `feat: port ISO normalization` | 6 |
| 8 | 4 | test | `test: add focus point detection tests (TDD)` | 7 |
| 9 | 4 | feat | `feat: port focus point detection` | 8 |
| 10 | 5 | test | `test: add advanced config tests (TDD)` | 9 |
| 11 | 5 | feat | `feat: port advanced config parameters` | 10 |
| 12 | 6 | test | `test: add picked flag tests (TDD)` | 11 |
| 13 | 6 | feat | `feat: port picked flag calculation` | 12 |
| 14 | 7 | test | `test: add burst pHash tests (TDD)` | 13 |
| 15 | 7 | feat | `feat: port burst pHash verification` | 14 |
| 16 | — | test | `test: integration test with real photos` | 15 |

### Dependency Graph

```
1 (plan)
└─ 2-3 (task 1: sharpness)
   └─ 4-5 (task 2: rating engine)
      └─ 6 (task 3: ISO)
         └─ 7 (task 4: focus point)
            └─ 8-9 (task 5: config)
               └─ 10 (task 6: picked flag)
                  └─ 11 (task 7: burst pHash)
                     └─ 12 (integration test)
```

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| ImageIO doesn't expose AF fields for all camera brands | high | Start with Sony ARW (SubjectArea); fallback to (1.0, 1.0) for unsupported cameras; add brands incrementally |
| pHash requires DCT implementation | medium | Use vDSP_DCT from Accelerate framework; or simple average-hash as fallback |
| Score distribution differs between Mac and Python | medium | Integration test compares scores on same real-photos folder; accept ±10% tolerance |
| Config migration for existing users | low | New params get defaults matching superpicky; existing settings preserved |

---

## In Scope (previously incorrectly excluded)

- **Segmentation mask intersection**: preen's detector returns seg masks (`yolo11l-seg.pt`) when available. FocusPointDetector should use seg mask for Layer 2 vs Layer 3 distinction. HeadSharpness should intersect circle mask with seg mask.
- **Focus point detection with exiftool**: Port superpicky's multi-brand EXIF parsing. Bundle exiftool or use the existing Python server as a proxy for AF data extraction.
- **Flying bonus: multiplicative only**: `rating_sharpness = head_sharpness + 100` in photo_processor.py line 1876 is dead code (the variable is never passed to the rating engine — `normalized_sharpness` is used instead). Only the multiplicative bonus in rating_engine (×1.2, ×1.1) is active. The existing Swift implementation is already correct.

## Out of Scope

- Metadata write modes (embedded/sidecar/inplace) — Mac already uses XMP sidecar only

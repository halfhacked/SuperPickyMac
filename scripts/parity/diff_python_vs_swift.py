#!/usr/bin/env python3
"""Diff the Python reference (generate_python_reference.py) against the
Swift `.report.db` that `SuperPicky.app` writes into the processed folder.

Per-model tolerances are first-pass — they catch regressions wider than
fp16 + small preprocessing jitter, not bit-exact numerical parity. Adjust
after running on real data; keep the rationale in scripts/parity/README.md.

Invocation:
    python3 scripts/parity/diff_python_vs_swift.py \\
        --reference real-photos/.parity-python.json \\
        --swift-db  real-photos/.report.db

Exit code 0 if every model is within tolerance, 1 otherwise.
"""
from __future__ import annotations

import argparse
import json
import sqlite3
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# --- Tolerances ----------------------------------------------------------------
# Baseline observations on real-photos (156 RAW bird photos, 2026-04-15) are
# noted next to each threshold. The rule: decisions/presence are strict; raw
# confidence values are informational because CoreML runs in fp16 on the ANE
# and JPEG/letterbox preprocessing isn't byte-identical.

# Flight — EfficientNet-B3 binary classifier.
# Observed: decision agreement 98.7 %, conf p95 Δ 0.167 (near-threshold cases).
FLIGHT_MIN_DECISION_AGREEMENT = 0.95
FLIGHT_MAX_CONF_DELTA = 0.20           # p95 on photos where decisions match

# YOLO — both sides run yolo11l-seg but Swift's letterbox + NMS vs
# ultralytics' internal pipeline produce slightly different confidences
# on the same bird. Presence is what matters downstream.
# Observed: presence disagree 0.7 %, conf p95 Δ 0.12.
YOLO_MAX_PRESENCE_DISAGREE = 0.03
YOLO_MAX_CONF_DELTA = 0.25             # p95 on photos where both detected a bird

# Species — ResNet34 10k-way classifier, top-1 agreement.
# Observed: 99.3 % agreement, conf p95 Δ 0.068.
SPECIES_MIN_AGREEMENT = 0.90
SPECIES_MAX_CONF_DELTA_P95 = 0.20

# Keypoints — ResNet50 coord regression.
# Observed: coord p95 Δ 0.039, vis p95 Δ 0.059.
KEYPOINT_MAX_COORD_DELTA_P95 = 0.08
KEYPOINT_MAX_VIS_DELTA_P95 = 0.15

# Aesthetics — CFANet / TOPIQ regression, MOS in [1, 10].
# Observed: p50 Δ 0.03, p95 Δ 0.11, max Δ 0.15.
AESTHETICS_MAX_MOS_DELTA_P95 = 0.5
AESTHETICS_MAX_MOS_DELTA_MAX = 1.0

# Aesthetics distribution — 10-bin AVA distribution (sums to 1, L1 ≤ 2).
# A non-zero MOS delta can come from a small shift in the distribution, but
# a bimodal divergence (fp16 saturation, preprocessing drift) shows up as a
# fat L1 even when MOS happens to agree.
AESTHETICS_DIST_MAX_L1_P95 = 0.30
AESTHETICS_DIST_MAX_L1_MAX = 0.50

# Top-5 overlap (species) — Jaccard(|top5_py ∩ top5_sw| / |top5_py ∪ top5_sw|)
# and "top-1 ∈ other's top-5" inclusion rate. Catches near-threshold waffling
# where top-1 agrees nominally but the second choice has drifted.
SPECIES_TOP5_MIN_JACCARD = 0.60        # p50 across photos with ≥3 matches each side
SPECIES_TOP5_MIN_INCLUSION = 0.95      # each side's top-1 should be in the other's top-5

# Pinyin agreement — exact-string match rate on photos where BOTH sides have
# a Chinese name. Currently both sides leave pinyin = NULL (neither side has a
# pinyin column populated), so the natural agreement is 100% on null==null
# AND on any populated pair. The check flags drift if one side starts
# populating it without the other.
PINYIN_MIN_AGREEMENT = 0.98

# YOLO bbox IoU — intersection-over-union on the normalized
# [x1, y1, x2, y2] rectangle from the highest-confidence detection. If the
# bbox drifts, every downstream model (flight, keypoint, OSEA) drifts too.
BBOX_MIN_IOU_P50 = 0.80
# "Worst" IoU — the 5th-percentile (bottom 5% of photos). A low p5 means
# a long tail of photos where the bbox diverged significantly.
BBOX_MIN_IOU_P5_WORST = 0.60

COORD_FIELDS = (
    ("leftEyeX", "leftEyeY", "leftEyeVis"),
    ("rightEyeX", "rightEyeY", "rightEyeVis"),
    ("beakX", "beakY", "beakVis"),
)


@dataclass
class ModelResult:
    name: str
    passed: bool
    lines: list[str] = field(default_factory=list)


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    k = max(0, min(len(values) - 1, int(round((pct / 100.0) * (len(values) - 1)))))
    return values[k]


def _load_swift_db(path: Path) -> dict[str, dict]:
    conn = sqlite3.connect(str(path))
    conn.row_factory = sqlite3.Row
    cur = conn.execute("SELECT * FROM photos")
    rows = {row["filename"]: dict(row) for row in cur.fetchall()}
    conn.close()
    return rows


def _check_flight(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    matches, disagreements, conf_deltas = 0, [], []
    for k in common:
        p = py[k]
        s = swift[k]
        if p.get("flightConfidence") is None or s.get("flightConfidence") is None:
            continue
        p_fly = bool(p.get("isFlying"))
        s_fly = bool(s.get("isFlying"))
        if p_fly == s_fly:
            matches += 1
            conf_deltas.append(abs(float(p["flightConfidence"]) - float(s["flightConfidence"])))
        else:
            disagreements.append((k, s_fly, s["flightConfidence"], p_fly, p["flightConfidence"]))

    total = matches + len(disagreements)
    agreement = matches / total if total else 1.0
    max_delta = max(conf_deltas) if conf_deltas else 0.0
    p95 = _percentile(conf_deltas, 95)

    lines = [
        f"Compared {total} photos (both have flight output)",
        f"Decision agreement: {matches}/{total} ({agreement:.1%}) [threshold ≥ {FLIGHT_MIN_DECISION_AGREEMENT:.0%}]",
        f"Confidence Δ on matches: p95={p95:.3f} max={max_delta:.3f} [threshold < {FLIGHT_MAX_CONF_DELTA}]",
    ]
    if disagreements:
        lines.append(f"Disagreements ({len(disagreements)}):")
        for name, s_fly, s_conf, p_fly, p_conf in sorted(disagreements)[:10]:
            lines.append(
                f"  {name}: swift={s_fly}({s_conf:.3f}) python={p_fly}({p_conf:.3f})"
            )
        if len(disagreements) > 10:
            lines.append(f"  … {len(disagreements) - 10} more")
    ok = agreement >= FLIGHT_MIN_DECISION_AGREEMENT and p95 < FLIGHT_MAX_CONF_DELTA
    return ModelResult("FLIGHT", ok, lines)


def _check_yolo(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    both, only_py, only_sw, deltas, bad = 0, 0, 0, [], []
    for k in common:
        p_conf = py[k].get("birdConfidence")
        s_conf = swift[k].get("birdConfidence")
        if p_conf is None and s_conf is None:
            continue
        if p_conf is None:
            only_sw += 1
            continue
        if s_conf is None:
            only_py += 1
            continue
        both += 1
        d = abs(float(p_conf) - float(s_conf))
        deltas.append(d)
        if d >= YOLO_MAX_CONF_DELTA:
            bad.append((k, float(s_conf), float(p_conf), d))

    total = both + only_py + only_sw
    presence_disagree_rate = (only_py + only_sw) / total if total else 0.0
    p95 = _percentile(deltas, 95)
    max_delta = max(deltas) if deltas else 0.0

    lines = [
        f"Photos where both sides detected a bird: {both}/{total} (presence-disagree rate {presence_disagree_rate:.1%}, threshold < {YOLO_MAX_PRESENCE_DISAGREE:.0%})",
        f"birdConfidence Δ: p95={p95:.3f} max={max_delta:.3f} [threshold < {YOLO_MAX_CONF_DELTA}]",
    ]
    if only_py or only_sw:
        lines.append(f"Only-Python detections: {only_py}   Only-Swift detections: {only_sw}")
    if bad:
        lines.append(f"Confidence mismatches ({len(bad)}):")
        for name, s_c, p_c, d in sorted(bad, key=lambda x: -x[3])[:10]:
            lines.append(f"  {name}: swift={s_c:.3f} python={p_c:.3f} Δ={d:.3f}")
    ok = presence_disagree_rate < YOLO_MAX_PRESENCE_DISAGREE and p95 < YOLO_MAX_CONF_DELTA
    return ModelResult("YOLO / BIRD", ok, lines)


def _check_species(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    both_ided, matches, mismatches, conf_deltas = 0, 0, [], []
    for k in common:
        p_name = py[k].get("speciesScientificName")
        s_name = swift[k].get("speciesScientificName")
        if not p_name or not s_name:
            continue
        both_ided += 1
        if p_name == s_name:
            matches += 1
            if py[k].get("speciesConfidence") is not None and swift[k].get("speciesConfidence") is not None:
                conf_deltas.append(abs(float(py[k]["speciesConfidence"]) - float(swift[k]["speciesConfidence"])))
        else:
            mismatches.append((k, s_name, py[k].get("speciesCommonName") or "", p_name, py[k].get("speciesCommonName") or ""))

    agreement = matches / both_ided if both_ided else 1.0
    p95 = _percentile(conf_deltas, 95)

    lines = [
        f"Both sides identified a species on {both_ided} photos",
        f"Top-1 agreement: {matches}/{both_ided} ({agreement:.1%}) [threshold ≥ {SPECIES_MIN_AGREEMENT:.0%}]",
        f"Confidence Δ p95 on matches: {p95:.3f} [threshold < {SPECIES_MAX_CONF_DELTA_P95}]",
    ]
    if mismatches:
        lines.append(f"Mismatches ({len(mismatches)}):")
        for name, s_name, s_common, p_name, p_common in sorted(mismatches)[:10]:
            lines.append(f"  {name}: swift={s_name!r} python={p_name!r}")
        if len(mismatches) > 10:
            lines.append(f"  … {len(mismatches) - 10} more")
    ok = agreement >= SPECIES_MIN_AGREEMENT and p95 < SPECIES_MAX_CONF_DELTA_P95
    return ModelResult("SPECIES (OSEA)", ok, lines)


def _check_keypoints(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    coord_deltas, vis_deltas, compared = [], [], 0
    worst = []  # (delta, filename, field)

    for k in common:
        p, s = py[k], swift[k]
        # skip photos where either side had no bird crop
        if p.get("leftEyeX") is None or s.get("leftEyeX") is None:
            continue
        compared += 1
        for x_field, y_field, v_field in COORD_FIELDS:
            for coord_field in (x_field, y_field):
                pv, sv = p.get(coord_field), s.get(coord_field)
                if pv is None or sv is None:
                    continue
                d = abs(float(pv) - float(sv))
                coord_deltas.append(d)
                worst.append((d, k, coord_field))
            pv_vis, sv_vis = p.get(v_field), s.get(v_field)
            if pv_vis is not None and sv_vis is not None:
                vis_deltas.append(abs(float(pv_vis) - float(sv_vis)))

    coord_p95 = _percentile(coord_deltas, 95)
    coord_max = max(coord_deltas) if coord_deltas else 0.0
    vis_p95 = _percentile(vis_deltas, 95)

    lines = [
        f"Photos compared (both have keypoints): {compared}",
        f"Coord Δ: p95={coord_p95:.3f} max={coord_max:.3f} [threshold p95 < {KEYPOINT_MAX_COORD_DELTA_P95}]",
        f"Visibility Δ: p95={vis_p95:.3f} [threshold p95 < {KEYPOINT_MAX_VIS_DELTA_P95}]",
    ]
    worst.sort(reverse=True)
    if worst and worst[0][0] > 0.05:
        lines.append("Worst coord deltas:")
        for d, name, field_name in worst[:5]:
            lines.append(f"  {name} {field_name}: Δ={d:.3f}")
    ok = coord_p95 < KEYPOINT_MAX_COORD_DELTA_P95 and vis_p95 < KEYPOINT_MAX_VIS_DELTA_P95
    return ModelResult("KEYPOINTS", ok, lines)


def _json_or_none(text: Optional[str]):
    """Swift persists list/array parity fields as JSON-encoded TEXT columns.
    Decode them here; return None on missing/blank/invalid JSON."""
    if not text:
        return None
    try:
        return json.loads(text)
    except (TypeError, ValueError):
        return None


def _sci_names(top5_raw) -> list[str]:
    """Extract scientific names from a top-5 list, tolerating either side's
    serialization conventions. Swift SpeciesMatch uses CodingKey `name` for
    the scientific name; the Python reference mirrors that."""
    if not isinstance(top5_raw, list):
        return []
    names: list[str] = []
    for item in top5_raw:
        if not isinstance(item, dict):
            continue
        name = item.get("name") or item.get("scientificName") or item.get("scientific_name")
        if name:
            names.append(str(name))
    return names


def _check_species_top5(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    jaccards: list[float] = []
    inclusion_py_in_sw = 0
    inclusion_sw_in_py = 0
    inclusion_trials = 0
    bad: list[tuple[str, float, list[str], list[str]]] = []

    for k in common:
        p_top5_raw = py[k].get("speciesTop5")
        s_top5_raw = _json_or_none(swift[k].get("speciesTop5JSON"))
        p_names = _sci_names(p_top5_raw)
        s_names = _sci_names(s_top5_raw)
        if len(p_names) < 1 or len(s_names) < 1:
            continue

        p_set, s_set = set(p_names), set(s_names)
        inter = len(p_set & s_set)
        union = len(p_set | s_set)
        jac = inter / union if union else 1.0
        jaccards.append(jac)

        inclusion_trials += 1
        if p_names[0] in s_set:
            inclusion_py_in_sw += 1
        if s_names[0] in p_set:
            inclusion_sw_in_py += 1

        if jac < 0.5:
            bad.append((k, jac, s_names, p_names))

    p50_j = _percentile(jaccards, 50)
    # "Worst" Jaccard: the 5th percentile (i.e., the value below which only
    # 5% of photos fall). Used as the lower-bound guard; a small p5 means
    # a long tail of photos with poor top-5 agreement.
    p5_j_worst = _percentile(jaccards, 5)
    inc_py = inclusion_py_in_sw / inclusion_trials if inclusion_trials else 1.0
    inc_sw = inclusion_sw_in_py / inclusion_trials if inclusion_trials else 1.0

    lines = [
        f"Photos with top-5 on both sides: {len(jaccards)}",
        f"Top-5 Jaccard: p50={p50_j:.2f} p5(worst)={p5_j_worst:.2f} [threshold p50 ≥ {SPECIES_TOP5_MIN_JACCARD:.2f}]",
        f"Top-1 in other's top-5: py→sw={inc_py:.1%} sw→py={inc_sw:.1%} [threshold ≥ {SPECIES_TOP5_MIN_INCLUSION:.0%}]",
    ]
    if bad:
        lines.append(f"Weakest overlaps ({len(bad)}):")
        for name, j, s_names, p_names in sorted(bad, key=lambda x: x[1])[:5]:
            lines.append(f"  {name}: J={j:.2f} swift={s_names[:3]} python={p_names[:3]}")
    ok = (p50_j >= SPECIES_TOP5_MIN_JACCARD
          and min(inc_py, inc_sw) >= SPECIES_TOP5_MIN_INCLUSION)
    return ModelResult("SPECIES TOP-5", ok, lines)


def _check_pinyin(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    both_have_cn, matches, mismatches = 0, 0, []
    for k in common:
        p_cn = py[k].get("speciesCnName")
        s_cn = swift[k].get("speciesCnName")
        if not p_cn or not s_cn:
            continue
        both_have_cn += 1
        p_py = py[k].get("speciesPinyin")
        s_py = swift[k].get("speciesPinyin")
        # Normalize None / empty string so "" == None counts as agreement.
        if (p_py or None) == (s_py or None):
            matches += 1
        else:
            mismatches.append((k, s_py, p_py))
    rate = matches / both_have_cn if both_have_cn else 1.0
    lines = [
        f"Photos where both sides have a Chinese name: {both_have_cn}",
        f"Pinyin exact-match rate: {matches}/{both_have_cn} ({rate:.1%}) [threshold ≥ {PINYIN_MIN_AGREEMENT:.0%}]",
    ]
    if mismatches:
        lines.append(f"Mismatches ({len(mismatches)}):")
        for name, s_py, p_py in sorted(mismatches)[:10]:
            lines.append(f"  {name}: swift={s_py!r} python={p_py!r}")
    ok = rate >= PINYIN_MIN_AGREEMENT
    return ModelResult("SPECIES PINYIN", ok, lines)


def _check_aesthetics_distribution(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    deltas: list[float] = []
    worst: list[tuple[float, str]] = []
    for k in common:
        p_dist = py[k].get("aestheticsDistribution")
        s_dist = _json_or_none(swift[k].get("aestheticsDistributionJSON"))
        if not isinstance(p_dist, list) or not isinstance(s_dist, list):
            continue
        n = min(len(p_dist), len(s_dist))
        if n < 10:
            continue
        l1 = sum(abs(float(p_dist[i]) - float(s_dist[i])) for i in range(n))
        deltas.append(l1)
        worst.append((l1, k))
    p50 = _percentile(deltas, 50)
    p95 = _percentile(deltas, 95)
    mx = max(deltas) if deltas else 0.0
    lines = [
        f"Photos compared (both have 10-bin distribution): {len(deltas)}",
        f"Distribution L1 Δ: p50={p50:.3f} p95={p95:.3f} max={mx:.3f} [thresholds: p95 < {AESTHETICS_DIST_MAX_L1_P95}, max < {AESTHETICS_DIST_MAX_L1_MAX}]",
    ]
    worst.sort(reverse=True)
    if worst and worst[0][0] > AESTHETICS_DIST_MAX_L1_P95:
        lines.append("Worst L1 deltas:")
        for d, name in worst[:5]:
            lines.append(f"  {name}: L1={d:.3f}")
    ok = p95 < AESTHETICS_DIST_MAX_L1_P95 and mx < AESTHETICS_DIST_MAX_L1_MAX
    return ModelResult("AESTHETICS DISTRIBUTION", ok, lines)


def _iou(a: list[float], b: list[float]) -> float:
    """IoU on [x1, y1, x2, y2] rectangles. Tolerant of unordered corners."""
    ax1, ax2 = min(a[0], a[2]), max(a[0], a[2])
    ay1, ay2 = min(a[1], a[3]), max(a[1], a[3])
    bx1, bx2 = min(b[0], b[2]), max(b[0], b[2])
    by1, by2 = min(b[1], b[3]), max(b[1], b[3])
    ix1, iy1 = max(ax1, bx1), max(ay1, by1)
    ix2, iy2 = min(ax2, bx2), min(ay2, by2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    inter = iw * ih
    aarea = max(0.0, ax2 - ax1) * max(0.0, ay2 - ay1)
    barea = max(0.0, bx2 - bx1) * max(0.0, by2 - by1)
    union = aarea + barea - inter
    return inter / union if union > 0 else 0.0


def _check_bbox_iou(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    ious: list[float] = []
    worst: list[tuple[float, str]] = []
    for k in common:
        p_bbox = py[k].get("birdBbox")
        s_bbox = _json_or_none(swift[k].get("birdBboxJSON"))
        if not (isinstance(p_bbox, list) and len(p_bbox) == 4):
            continue
        if not (isinstance(s_bbox, list) and len(s_bbox) == 4):
            continue
        iou = _iou([float(x) for x in p_bbox], [float(x) for x in s_bbox])
        ious.append(iou)
        worst.append((iou, k))
    p50 = _percentile(ious, 50)
    # 5th percentile = the 5% worst — mirrors the "min IoU" concept.
    p5_worst = _percentile(ious, 5)
    mn = min(ious) if ious else 1.0
    lines = [
        f"Photos compared (both have bbox): {len(ious)}",
        f"Bbox IoU: p50={p50:.2f} p5(worst)={p5_worst:.2f} min={mn:.2f} [thresholds: p50 ≥ {BBOX_MIN_IOU_P50}, p5 ≥ {BBOX_MIN_IOU_P5_WORST}]",
    ]
    worst.sort()
    if worst and worst[0][0] < BBOX_MIN_IOU_P5_WORST:
        lines.append("Worst IoUs:")
        for iou, name in worst[:5]:
            lines.append(f"  {name}: IoU={iou:.2f}")
    ok = p50 >= BBOX_MIN_IOU_P50 and p5_worst >= BBOX_MIN_IOU_P5_WORST
    return ModelResult("YOLO BBOX IOU", ok, lines)


def _check_aesthetics(py: dict, swift: dict) -> ModelResult:
    common = py.keys() & swift.keys()
    deltas, worst = [], []
    for k in common:
        pv, sv = py[k].get("aestheticsScore"), swift[k].get("aestheticsScore")
        if pv is None or sv is None:
            continue
        d = abs(float(pv) - float(sv))
        deltas.append(d)
        worst.append((d, k, float(sv), float(pv)))
    p50 = _percentile(deltas, 50)
    p95 = _percentile(deltas, 95)
    mx = max(deltas) if deltas else 0.0

    lines = [
        f"Photos compared: {len(deltas)}",
        f"MOS Δ: p50={p50:.2f} p95={p95:.2f} max={mx:.2f} [thresholds: p95 < {AESTHETICS_MAX_MOS_DELTA_P95}, max < {AESTHETICS_MAX_MOS_DELTA_MAX}]",
    ]
    worst.sort(reverse=True)
    if worst and worst[0][0] > 0.3:
        lines.append("Worst MOS deltas:")
        for d, name, s_v, p_v in worst[:5]:
            lines.append(f"  {name}: swift={s_v:.2f} python={p_v:.2f} Δ={d:.2f}")
    ok = p95 < AESTHETICS_MAX_MOS_DELTA_P95 and mx < AESTHETICS_MAX_MOS_DELTA_MAX
    return ModelResult("AESTHETICS (TOPIQ)", ok, lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--reference", required=True)
    ap.add_argument("--swift-db", required=True)
    args = ap.parse_args()

    ref_path = Path(args.reference).expanduser().resolve()
    db_path = Path(args.swift_db).expanduser().resolve()

    if not ref_path.exists():
        print(f"ERROR: reference JSON not found: {ref_path}", file=sys.stderr)
        return 2
    if not db_path.exists():
        print(f"ERROR: swift report.db not found: {db_path}", file=sys.stderr)
        return 2

    reference = json.loads(ref_path.read_text())
    py_photos = reference["photos"]
    swift_photos = _load_swift_db(db_path)

    print(f"Reference: {ref_path} ({reference.get('photo_count', len(py_photos))} photos)")
    print(f"Swift DB:  {db_path} ({len(swift_photos)} photos)")
    print(f"Intersection: {len(py_photos.keys() & swift_photos.keys())} photos\n")

    checks = [
        _check_flight(py_photos, swift_photos),
        _check_yolo(py_photos, swift_photos),
        _check_bbox_iou(py_photos, swift_photos),
        _check_species(py_photos, swift_photos),
        _check_species_top5(py_photos, swift_photos),
        _check_pinyin(py_photos, swift_photos),
        _check_keypoints(py_photos, swift_photos),
        _check_aesthetics(py_photos, swift_photos),
        _check_aesthetics_distribution(py_photos, swift_photos),
    ]

    overall_ok = True
    for c in checks:
        verdict = "PASS" if c.passed else "FAIL"
        print(f"=== {c.name} [{verdict}] ===")
        for line in c.lines:
            print(f"  {line}")
        print()
        overall_ok &= c.passed

    print(f"OVERALL: {'PASS — all models within tolerance' if overall_ok else 'FAIL — see per-model blocks above'}")
    return 0 if overall_ok else 1


if __name__ == "__main__":
    sys.exit(main())

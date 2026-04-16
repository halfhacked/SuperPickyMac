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
        _check_species(py_photos, swift_photos),
        _check_keypoints(py_photos, swift_photos),
        _check_aesthetics(py_photos, swift_photos),
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

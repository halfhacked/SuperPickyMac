#!/usr/bin/env python3
"""Generate a per-photo reference of Python-model outputs for parity testing.

Runs every upstream model from ~/projects/SuperPicky on a folder of photos
and writes a JSON report mirroring the fields the Swift pipeline writes into
.report.db. The companion script scripts/parity/diff_python_vs_swift.py diffs
that reference against the Swift DB and reports per-model agreement.

Must run under ~/projects/SuperPicky/.venv so torch/ultralytics/PIL are
available and the SuperPicky source imports resolve.

Invocation:
    ~/projects/SuperPicky/.venv/bin/python \\
        scripts/parity/generate_python_reference.py \\
        --folder real-photos \\
        --output real-photos/.parity-python.json
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import logging
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image

# SuperPicky source lives here; its modules assume it is on sys.path.
SUPERPICKY = Path.home() / "projects" / "SuperPicky"
sys.path.insert(0, str(SUPERPICKY))
sys.path.insert(0, str(SUPERPICKY / "birdid"))

from birdid.avonet_filter import AvonetFilter  # noqa: E402
from birdid.bird_identifier import YOLOBirdDetector, extract_gps_from_exif, load_image  # noqa: E402
from birdid.osea_classifier import OSEAClassifier  # noqa: E402
from core.flight_detector import FlightDetector  # noqa: E402
from core.keypoint_detector import KeypointDetector  # noqa: E402
from topiq_model import TOPIQScorer  # noqa: E402

# Max dimension the Swift RAWConverter produces for inference inputs.
# Mirror it here so both paths see comparable-resolution thumbnails.
INFERENCE_MAX_SIDE = 1280

RAW_EXTS = {".arw", ".cr2", ".cr3", ".nef", ".raf", ".orf", ".rw2", ".pef", ".dng"}
IMG_EXTS = RAW_EXTS | {".jpg", ".jpeg", ".png", ".heic", ".hif", ".heif"}

log = logging.getLogger("parity-ref")


def loaded_image_at_inference_resolution(path: Path) -> Image.Image:
    """Load a photo and downscale to INFERENCE_MAX_SIDE — matches
    RAWConverter.maxInferenceSize. Uses SuperPicky's load_image() so the
    embedded-JPEG preview extraction is identical to Python inference."""
    image = load_image(str(path))
    w, h = image.size
    scale = min(1.0, INFERENCE_MAX_SIDE / max(w, h))
    if scale < 1.0:
        image = image.resize((int(round(w * scale)), int(round(h * scale))), Image.LANCZOS)
    return image


def _null_result() -> dict:
    """Null-filled record for photos where YOLO found no bird."""
    return {
        "birdConfidence": None,
        "speciesScientificName": None,
        "speciesCommonName": None,
        "speciesCnName": None,
        "speciesPinyin": None,
        "speciesConfidence": None,
        "leftEyeX": None, "leftEyeY": None, "leftEyeVis": None,
        "rightEyeX": None, "rightEyeY": None, "rightEyeVis": None,
        "beakX": None, "beakY": None, "beakVis": None,
        "isFlying": False,
        "flightConfidence": None,
        "aestheticsScore": None,
        # Extended parity fields — mirror the Swift .report.db columns.
        "speciesTop5": None,
        "aestheticsDistribution": None,
        "birdBbox": None,           # [x1, y1, x2, y2] normalized
        "gps": None,                # [lat, lon] decimal degrees, or null
    }


def process_photo(
    path: Path,
    yolo: YOLOBirdDetector,
    flight: FlightDetector,
    keypoint: KeypointDetector,
    osea: OSEAClassifier,
    aesthetics: TOPIQScorer,
    species_filter: AvonetFilter | None,
) -> dict:
    """Run all 5 upstream models on one photo and return DB-shaped fields."""
    out = _null_result()

    # GPS extraction + regional filter (mirrors Swift identify's cascade).
    allowed_ids: set[int] | None = None
    try:
        lat, lon, _ = extract_gps_from_exif(str(path))
    except Exception:
        lat, lon = None, None
    if lat is not None and lon is not None:
        out["gps"] = [float(lat), float(lon)]
        if species_filter is not None:
            ids = species_filter.get_species_by_gps(lat, lon)
            if not ids:
                country_ids, _ = species_filter.get_species_by_country_ebird(lat, lon)
                ids = country_ids
            allowed_ids = ids if ids else None

    try:
        image = loaded_image_at_inference_resolution(path)
    except Exception as e:
        log.error("%s load failed: %s", path.name, e)
        return out

    # Aesthetics: TOPIQScorer.calculate_score takes a file path and opens
    # it with PIL, which can't read RAW. Run the same preprocessing path
    # inline so we can also extract the 10-bin distribution alongside MOS.
    try:
        import torch
        import torchvision.transforms as T
        model = aesthetics._load_model()
        aesthetic_img = image.resize((384, 384), Image.LANCZOS)
        img_tensor = T.ToTensor()(aesthetic_img).unsqueeze(0).to(aesthetics.device)
        with torch.no_grad():
            dist_tensor = model(img_tensor, return_mos=False, return_dist=True)
            dist_values = dist_tensor.squeeze().cpu().numpy().tolist()
        mos_value = sum((i + 1) * p for i, p in enumerate(dist_values))
        out["aestheticsScore"] = float(mos_value)
        out["aestheticsDistribution"] = [float(v) for v in dist_values]
    except Exception as e:
        log.warning("%s aesthetics failed: %s", path.name, e)

    # YOLO bbox + smart-square crop. We run ultralytics directly once so
    # we capture the bbox for the parity harness, then use
    # detect_and_crop_bird for the exact same crop the Python inference
    # pipeline uses downstream.
    try:
        img_array = np.array(image)
        results = yolo.model(img_array, conf=0.25, verbose=False)
        detections = []
        for result in results:
            if result.boxes is None:
                continue
            for box in result.boxes:
                class_id = int(box.cls[0].cpu().numpy())
                if class_id != 14:
                    continue
                x1, y1, x2, y2 = box.xyxy[0].cpu().numpy().tolist()
                detections.append({
                    "bbox": [float(x1), float(y1), float(x2), float(y2)],
                    "confidence": float(box.conf[0].cpu().numpy()),
                })
        if detections:
            best = max(detections, key=lambda d: d["confidence"])
            out["birdConfidence"] = best["confidence"]
            # Normalize bbox to [0, 1] against the thumbnail we fed to YOLO.
            w, h = image.size
            x1, y1, x2, y2 = best["bbox"]
            out["birdBbox"] = [x1 / w, y1 / h, x2 / w, y2 / h]
    except Exception as e:
        log.warning("%s yolo failed: %s", path.name, e)

    # Use detect_and_crop_bird for the smart-square + letterbox crop that
    # mirrors Swift. This re-runs YOLO internally; cheap enough for the
    # test set, simplifies the code path.
    try:
        crop, info = yolo.detect_and_crop_bird(
            image,
            confidence_threshold=0.25,
            padding_ratio=0.15,
        )
    except Exception as e:
        log.warning("%s yolo crop failed: %s", path.name, e)
        crop, info = None, str(e)

    if crop is None:
        return out

    crop_rgb = np.array(crop)

    # Flight — Python accepts RGB np.ndarray directly.
    try:
        flight.load_model()
        fr = flight.detect(crop_rgb)
        out["isFlying"] = bool(fr.is_flying)
        out["flightConfidence"] = float(fr.confidence)
    except Exception as e:
        log.warning("%s flight failed: %s", path.name, e)

    # Keypoints — same RGB crop.
    try:
        kp = keypoint.detect(crop_rgb)
        if kp is not None:
            out["leftEyeX"], out["leftEyeY"] = float(kp.left_eye[0]), float(kp.left_eye[1])
            out["rightEyeX"], out["rightEyeY"] = float(kp.right_eye[0]), float(kp.right_eye[1])
            out["beakX"], out["beakY"] = float(kp.beak[0]), float(kp.beak[1])
            out["leftEyeVis"] = float(kp.left_eye_vis)
            out["rightEyeVis"] = float(kp.right_eye_vis)
            out["beakVis"] = float(kp.beak_vis)
    except Exception as e:
        log.warning("%s keypoint failed: %s", path.name, e)

    # OSEA species — inline TTA (h-flip average) + masked softmax mirrors the
    # exact Swift CoreMLInferenceClient.identify path:
    #   - temperature=0.9
    #   - if allowed_ids is non-empty, mask disallowed class logits to -inf
    #     before softmax; if masked top-1 falls below the floor, retry global
    #   - drop near-zero probabilities (< 0.003) when picking top-5
    # Confidences in the output dict are normalized [0, 1] to match Swift DB.
    OSEA_TEMPERATURE = 0.9
    OSEA_FLOOR = 0.003
    try:
        import torch
        input1 = osea.transform(crop).unsqueeze(0).to(osea.device)
        flipped = crop.transpose(Image.FLIP_LEFT_RIGHT)
        input2 = osea.transform(flipped).unsqueeze(0).to(osea.device)
        osea.model.eval()
        with torch.no_grad():
            out1 = osea.model(input1)[0][: osea.num_classes]
            out2 = osea.model(input2)[0][: osea.num_classes]
        avg_logits = ((out1 + out2) / 2).detach().cpu().numpy()

        def _softmax(logits: np.ndarray) -> np.ndarray:
            scaled = logits / OSEA_TEMPERATURE
            m = float(np.max(scaled)) if scaled.size else 0.0
            exps = np.exp(scaled - m)
            s = float(exps.sum())
            return exps / s if s > 0 else exps

        probs = None
        if allowed_ids:
            masked = np.full_like(avg_logits, -np.inf)
            for idx in allowed_ids:
                if 0 <= idx < avg_logits.shape[0]:
                    masked[idx] = avg_logits[idx]
            masked_probs = _softmax(masked)
            if float(masked_probs.max()) >= OSEA_FLOOR:
                probs = masked_probs
            else:
                # Regional mask wiped every candidate → fall through to global
                # softmax, matching Swift's cascade.
                log.info("%s regional mask wiped candidates; falling back to global", path.name)
        if probs is None:
            probs = _softmax(avg_logits)

        # Top-5 with DB resolution; stop at floor.
        top_indices = np.argsort(-probs)[:5]
        top5: list[dict] = []
        for idx in top_indices:
            p = float(probs[idx])
            if p < OSEA_FLOOR:
                break
            info = osea.bird_info[int(idx)] if int(idx) < len(osea.bird_info) else None
            if not info:
                continue
            cn_name = info[0] if info[0] and info[0] != "Unknown" else None
            en_name = info[1] if info[1] and info[1] != "Unknown" else None
            sci_name = info[2] if len(info) > 2 and info[2] else None
            # Keys match Swift's SpeciesMatch Codable CodingKeys exactly so
            # the diff script can pull matching fields from both sides.
            top5.append({
                "classID": int(idx),
                "name": sci_name,         # scientificName on Swift
                "common_name": en_name,
                "cn_name": cn_name,
                "pinyin": None,           # neither side populates; parity is null==null
                "confidence": p,          # [0, 1]
                "threshold_used": "global" if not allowed_ids else "regional",
            })

        if top5:
            top = top5[0]
            out["speciesScientificName"] = top["name"]
            out["speciesCommonName"] = top["common_name"]
            out["speciesCnName"] = top["cn_name"]
            out["speciesPinyin"] = top["pinyin"]
            out["speciesConfidence"] = top["confidence"]
            out["speciesTop5"] = top5
    except Exception as e:
        log.warning("%s osea failed: %s", path.name, e)

    return out


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--folder", required=True, help="Folder containing photos to process.")
    ap.add_argument("--output", required=True, help="Where to write the JSON reference.")
    ap.add_argument("--limit", type=int, default=0, help="Limit number of photos (0 = all).")
    args = ap.parse_args()

    folder = Path(args.folder).expanduser().resolve()
    if not folder.is_dir():
        log.error("folder %s is not a directory", folder)
        return 2

    files = sorted(p for p in folder.iterdir() if p.suffix.lower() in IMG_EXTS and not p.name.startswith("."))
    if args.limit:
        files = files[: args.limit]
    log.info("Loading %d photos from %s", len(files), folder)

    log.info("Initializing Python models …")
    yolo = YOLOBirdDetector()
    flight = FlightDetector()
    keypoint = KeypointDetector()
    # Swift OSEAClassifier.logits uses the direct-resize 224×224 transform
    # when isYOLOCropped=true. Mirror it by disabling center-crop here so
    # both sides share the same preprocessing on YOLO bird crops.
    osea = OSEAClassifier(use_center_crop=False)
    aesthetics = TOPIQScorer()
    # AvonetFilter wraps the regional SQLite DB + eBird country JSONs and
    # implements the same cascade Swift SpeciesFilter does. If the DB isn't
    # present on disk, process_photo falls through to an unfiltered (global)
    # softmax — matches Swift's behavior when avonet.db hasn't been downloaded.
    try:
        species_filter: AvonetFilter | None = AvonetFilter()
    except Exception as e:
        log.warning("AvonetFilter init failed (%s); reference will be unfiltered", e)
        species_filter = None

    results: dict[str, dict] = {}
    t0 = time.time()
    for i, path in enumerate(files, 1):
        tp = time.time()
        results[path.name] = process_photo(
            path, yolo, flight, keypoint, osea, aesthetics, species_filter
        )
        log.info("[%d/%d] %s (%.2fs)", i, len(files), path.name, time.time() - tp)

    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "generator": "scripts/parity/generate_python_reference.py",
        "generated_at": dt.datetime.now(dt.UTC).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source_folder": str(folder),
        "photo_count": len(results),
        "wallclock_seconds": round(time.time() - t0, 1),
        "models": {
            "yolo": "ultralytics yolo11l-seg.pt",
            "flight": "superFlier_efficientnet.pth",
            "keypoint": "cub200_keypoint_resnet50_slim.pth",
            "osea": "model20240824.pth",
            "aesthetics": "cfanet_iaa_ava_res50-3cd62bb3.pth",
        },
        "photos": results,
    }
    output.write_text(json.dumps(payload, indent=2, ensure_ascii=False))
    log.info("Wrote %s (%d photos, %.1fs)", output, len(results), time.time() - t0)
    return 0


if __name__ == "__main__":
    sys.exit(main())

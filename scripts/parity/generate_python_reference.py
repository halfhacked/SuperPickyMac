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
import os
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
from PIL import Image

# SuperPicky source lives here; its modules assume it is on sys.path.
SUPERPICKY = Path.home() / "projects" / "SuperPicky"
sys.path.insert(0, str(SUPERPICKY))
sys.path.insert(0, str(SUPERPICKY / "birdid"))

from birdid.bird_identifier import YOLOBirdDetector, load_image  # noqa: E402
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
        "speciesConfidence": None,
        "leftEyeX": None, "leftEyeY": None, "leftEyeVis": None,
        "rightEyeX": None, "rightEyeY": None, "rightEyeVis": None,
        "beakX": None, "beakY": None, "beakVis": None,
        "isFlying": False,
        "flightConfidence": None,
        "aestheticsScore": None,
    }


def process_photo(
    path: Path,
    yolo: YOLOBirdDetector,
    flight: FlightDetector,
    keypoint: KeypointDetector,
    osea: OSEAClassifier,
    aesthetics: TOPIQScorer,
) -> dict:
    """Run all 5 upstream models on one photo and return DB-shaped fields."""
    out = _null_result()

    try:
        image = loaded_image_at_inference_resolution(path)
    except Exception as e:
        log.error("%s load failed: %s", path.name, e)
        return out

    # Aesthetics: TOPIQScorer.calculate_score takes a file path and opens it
    # with PIL, which can't read RAW. Swift's AestheticsModel runs on the
    # decoded 1280 px thumbnail — mirror that by writing the same thumbnail
    # to a temp JPEG and passing that path.
    tmp_jpeg = None
    try:
        fd, tmp_jpeg = tempfile.mkstemp(prefix="parity-", suffix=".jpg")
        os.close(fd)
        image.save(tmp_jpeg, format="JPEG", quality=95)
        mos = aesthetics.calculate_score(tmp_jpeg)
        out["aestheticsScore"] = float(mos) if mos is not None else None
    except Exception as e:
        log.warning("%s aesthetics failed: %s", path.name, e)
    finally:
        if tmp_jpeg and os.path.exists(tmp_jpeg):
            os.unlink(tmp_jpeg)

    # YOLO + smart-square crop. detect_and_crop_bird returns a PIL image
    # already expanded to max_side*(1+padding), centered, letterboxed.
    try:
        crop, info = yolo.detect_and_crop_bird(
            image,
            confidence_threshold=0.25,
            padding_ratio=0.15,
        )
    except Exception as e:
        log.warning("%s yolo failed: %s", path.name, e)
        crop, info = None, str(e)

    if crop is None:
        return out

    # detect_and_crop_bird prints "conf=0.xxx, size=(w,h)" — parse the conf.
    if info and info.startswith("conf="):
        try:
            out["birdConfidence"] = float(info.split("conf=")[1].split(",")[0])
        except ValueError:
            pass

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

    # OSEA species — Swift uses TTA (h-flip average) + temperature=0.9. Match
    # that by calling predict_with_tta with the same temperature. Confidence is
    # returned as percent [0, 100]; Swift DB stores [0, 1].
    try:
        results = osea.predict_with_tta(crop, top_k=1, temperature=0.9)
        if results:
            top = results[0]
            out["speciesScientificName"] = top.get("scientific_name") or None
            out["speciesCommonName"] = top.get("en_name") or None
            out["speciesCnName"] = top.get("cn_name") or None
            conf = top.get("confidence")
            out["speciesConfidence"] = float(conf) / 100.0 if conf is not None else None
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

    results: dict[str, dict] = {}
    t0 = time.time()
    for i, path in enumerate(files, 1):
        tp = time.time()
        results[path.name] = process_photo(path, yolo, flight, keypoint, osea, aesthetics)
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

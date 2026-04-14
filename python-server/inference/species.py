"""Species + detection — delegates entirely to preen."""
from typing import Any, Optional

from pypinyin import pinyin, Style

from preen.detector import BirdDetector
from preen.folder import load_folder_image, extract_gps

from inference._common import load_pil_image

REGIONAL_THRESHOLD = 80.0
GLOBAL_THRESHOLD = 90.0


def _to_pinyin(cn_name: str) -> str:
    if not cn_name:
        return ""
    return "".join(p[0] for p in pinyin(cn_name, style=Style.NORMAL, errors="ignore"))


def _format_species(result: Any, lat: Optional[float]) -> dict:
    return {
        "name": result.latin,
        "common_name": result.en_name,
        "confidence": result.confidence / 100.0,
        "cn_name": result.cn_name,
        "pinyin": _to_pinyin(result.cn_name),
        "threshold_used": "gps" if lat is not None else "global",
    }


class SpeciesClassifier:
    """Wraps preen's BirdDetector for the HTTP API."""

    def __init__(self, model_path: Optional[str] = None) -> None:
        self._detector: Optional[BirdDetector] = None

    def _get_detector(self) -> BirdDetector:
        if self._detector is None:
            self._detector = BirdDetector()
        return self._detector

    def predict_file(self, file_path: str, top_k: int = 5) -> dict:
        """Full pipeline: load image, extract GPS, detect birds, identify species.
        Returns species + bird bounding boxes (normalized 0-1). Single YOLO pass."""
        image = load_folder_image(file_path)
        lat, lon = extract_gps(file_path)
        w, h = image.size

        detector = self._get_detector()
        results, total_detected, bird_boxes = detector.detect_and_identify(
            image,
            threshold=REGIONAL_THRESHOLD,
            global_threshold=GLOBAL_THRESHOLD,
            lat=lat,
            lon=lon,
            return_boxes=True,
        )

        species = [_format_species(r, lat) for r in results[:top_k]]

        # Normalize bboxes to 0-1 (x1, y1, x2, y2 format — matches /detect endpoint)
        birds = [
            {
                "bbox": [x1 / w, y1 / h, x2 / w, y2 / h],
                "confidence": float(conf),
                "mask": "",
            }
            for x1, y1, x2, y2, conf in bird_boxes
        ]

        return {
            "species": species,
            "birds": birds,
            "total_detected": total_detected,
        }

    def predict(self, image_bytes: bytes, top_k: int = 5,
                temperature: float = 0.9,
                lat: Optional[float] = None,
                lon: Optional[float] = None) -> dict:
        """Legacy: identify from image bytes (used by tests)."""
        image = load_pil_image(image_bytes)

        detector = self._get_detector()
        results, total_detected = detector.detect_and_identify(
            image, threshold=REGIONAL_THRESHOLD,
            global_threshold=GLOBAL_THRESHOLD, lat=lat, lon=lon,
        )

        species = [_format_species(r, lat) for r in results[:top_k]]
        return {"species": species, "total_detected": total_detected}

"""Species identification — delegates entirely to preen's BirdDetector."""
from PIL import Image
from io import BytesIO
from pypinyin import pinyin, Style

from preen.detector import BirdDetector

REGIONAL_THRESHOLD = 80.0   # % confidence with GPS filter
GLOBAL_THRESHOLD = 90.0     # % confidence without GPS filter


def _to_pinyin(cn_name: str) -> str:
    if not cn_name:
        return ""
    return "".join(p[0] for p in pinyin(cn_name, style=Style.NORMAL, errors="ignore"))


class SpeciesClassifier:
    """Thin wrapper around preen's BirdDetector for the HTTP API."""

    def __init__(self, model_path: str = None):
        # model_path ignored — preen manages its own models
        self._detector = None

    def _get_detector(self):
        if self._detector is None:
            self._detector = BirdDetector()
        return self._detector

    def predict(self, image_bytes: bytes, top_k: int = 5,
                temperature: float = 0.9,
                lat: float = None, lon: float = None) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")

        detector = self._get_detector()
        results, total_detected = detector.detect_and_identify(
            image,
            threshold=REGIONAL_THRESHOLD,
            global_threshold=GLOBAL_THRESHOLD,
            lat=lat,
            lon=lon,
        )

        species = []
        for r in results[:top_k]:
            species.append({
                "name": r.latin,
                "common_name": r.en_name,
                "confidence": r.confidence / 100.0,
                "cn_name": r.cn_name,
                "pinyin": _to_pinyin(r.cn_name),
                "threshold_used": "gps" if lat is not None else "global",
            })

        return {
            "species": species,
            "total_detected": total_detected,
        }

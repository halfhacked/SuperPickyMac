"""Species identification — delegates entirely to preen."""
from pypinyin import pinyin, Style

from preen.detector import BirdDetector
from preen.folder import load_folder_image, extract_gps

REGIONAL_THRESHOLD = 80.0
GLOBAL_THRESHOLD = 90.0


def _to_pinyin(cn_name: str) -> str:
    if not cn_name:
        return ""
    return "".join(p[0] for p in pinyin(cn_name, style=Style.NORMAL, errors="ignore"))


class SpeciesClassifier:
    """Thin wrapper around preen's BirdDetector."""

    def __init__(self, model_path: str = None):
        self._detector = None

    def _get_detector(self):
        if self._detector is None:
            self._detector = BirdDetector()
        return self._detector

    def predict_file(self, file_path: str, top_k: int = 5) -> dict:
        """Identify birds in a file. Preen handles image loading, GPS extraction,
        YOLO detection, smart cropping, and OSEA classification."""
        image = load_folder_image(file_path)
        lat, lon = extract_gps(file_path)

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

    def predict(self, image_bytes: bytes, top_k: int = 5,
                temperature: float = 0.9,
                lat: float = None, lon: float = None) -> dict:
        """Legacy: identify from image bytes. Used by tests."""
        from PIL import Image
        from io import BytesIO
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

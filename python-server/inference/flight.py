"""Flight (in-flight vs perched) classifier."""
import os
import sys

from inference._common import load_pil_image
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class FlightPredictor:
    def __init__(self, model_path: str) -> None:
        self.device: str = get_best_device()
        from core.flight_detector import FlightDetector
        self.detector = FlightDetector(model_path=model_path)
        self.detector.load_model()

    def predict(self, image_bytes: bytes) -> dict:
        image = load_pil_image(image_bytes)
        result = self.detector.detect(image)
        return {"is_flying": result.is_flying, "confidence": float(result.confidence)}

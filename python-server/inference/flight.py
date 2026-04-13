import sys, os
from PIL import Image
from io import BytesIO
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class FlightPredictor:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        from core.flight_detector import FlightDetector
        self.detector = FlightDetector(model_path=model_path, device=self.device)

    def predict(self, image_bytes: bytes) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")
        result = self.detector.detect(image)
        return {"is_flying": result.is_flying, "confidence": float(result.confidence)}

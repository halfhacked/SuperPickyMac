import sys
import os
from PIL import Image
from io import BytesIO
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class SpeciesClassifier:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        from birdid.osea_classifier import OSEAClassifier
        self.classifier = OSEAClassifier(model_path=model_path, device=self.device)

    def predict(self, image_bytes: bytes, top_k: int = 5, temperature: float = 1.0) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")
        results = self.classifier.predict(image, top_k=top_k, temperature=temperature)
        species = []
        for r in results:
            species.append({
                "name": r.get("scientific_name", ""),
                "common_name": r.get("en_name", ""),
                "confidence": float(r.get("confidence", 0)) / 100.0,
            })
        return {"species": species}

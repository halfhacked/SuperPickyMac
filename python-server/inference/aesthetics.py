"""Aesthetics scoring via TOPIQ."""
import os
import sys

from inference._common import temp_image_file
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class AestheticsScorer:
    def __init__(self, model_path: str) -> None:
        self.device: str = get_best_device()
        from topiq_model import TOPIQScorer
        self.scorer = TOPIQScorer(device=self.device)

    def predict(self, image_bytes: bytes) -> dict:
        with temp_image_file(image_bytes) as tmp_path:
            result = self.scorer.calculate_score(tmp_path)
            return {"score": float(result), "distribution": []}

import sys
import os
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class AestheticsScorer:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        from topiq_model import TOPIQScorer
        self.scorer = TOPIQScorer(device=self.device)

    def score(self, image_bytes: bytes) -> dict:
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
            f.write(image_bytes)
            tmp_path = f.name
        try:
            result = self.scorer.calculate_score(tmp_path)
            return {"score": float(result), "distribution": []}
        finally:
            os.unlink(tmp_path)

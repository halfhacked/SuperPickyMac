import sys, os
import numpy as np
from PIL import Image
from io import BytesIO
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


class KeypointPredictor:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        from core.keypoint_detector import KeypointDetector
        self.detector = KeypointDetector(model_path=model_path)

    def predict(self, image_bytes: bytes) -> dict:
        image = Image.open(BytesIO(image_bytes)).convert("RGB")
        bird_crop = np.array(image)
        result = self.detector.detect(bird_crop)
        if result is None:
            return {"keypoints": {
                "left_eye": {"x": 0, "y": 0, "visibility": 0},
                "right_eye": {"x": 0, "y": 0, "visibility": 0},
                "beak": {"x": 0, "y": 0, "visibility": 0},
            }}
        return {"keypoints": {
            "left_eye": {"x": float(result.left_eye[0]), "y": float(result.left_eye[1]), "visibility": float(result.left_eye_vis)},
            "right_eye": {"x": float(result.right_eye[0]), "y": float(result.right_eye[1]), "visibility": float(result.right_eye_vis)},
            "beak": {"x": float(result.beak[0]), "y": float(result.beak[1]), "visibility": float(result.beak_vis)},
        }}

"""Bird keypoint (eye/beak) predictor."""
import os
import sys

import numpy as np

from inference._common import load_pil_image
from inference.device import get_best_device

SUPERPICKY_DIR = os.environ.get("SUPERPICKY_ORIGINAL", os.path.expanduser("~/projects/SuperPicky"))
if SUPERPICKY_DIR not in sys.path:
    sys.path.insert(0, SUPERPICKY_DIR)


_EMPTY_KEYPOINT = {"x": 0, "y": 0, "visibility": 0}


class KeypointPredictor:
    def __init__(self, model_path: str) -> None:
        self.device: str = get_best_device()
        from core.keypoint_detector import KeypointDetector
        self.detector = KeypointDetector(model_path=model_path)

    def predict(self, image_bytes: bytes) -> dict:
        image = load_pil_image(image_bytes)
        bird_crop = np.array(image)
        result = self.detector.detect(bird_crop)
        if result is None:
            return {"keypoints": {
                "left_eye": dict(_EMPTY_KEYPOINT),
                "right_eye": dict(_EMPTY_KEYPOINT),
                "beak": dict(_EMPTY_KEYPOINT),
            }}
        return {"keypoints": {
            "left_eye": {
                "x": float(result.left_eye[0]),
                "y": float(result.left_eye[1]),
                "visibility": float(result.left_eye_vis),
            },
            "right_eye": {
                "x": float(result.right_eye[0]),
                "y": float(result.right_eye[1]),
                "visibility": float(result.right_eye_vis),
            },
            "beak": {
                "x": float(result.beak[0]),
                "y": float(result.beak[1]),
                "visibility": float(result.beak_vis),
            },
        }}

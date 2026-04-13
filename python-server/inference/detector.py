import base64
import numpy as np
from ultralytics import YOLO
from inference.device import get_best_device


class BirdDetector:
    def __init__(self, model_path: str):
        self.device = get_best_device()
        self.model = YOLO(model_path)

    def detect(self, image_bytes: bytes) -> dict:
        import tempfile
        import os
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
            f.write(image_bytes)
            tmp_path = f.name
        try:
            results = self.model(tmp_path, device=self.device, verbose=False)
            birds = []
            if results and len(results) > 0:
                result = results[0]
                if result.boxes is not None:
                    img_h, img_w = result.orig_shape
                    for i in range(len(result.boxes)):
                        box = result.boxes[i]
                        x1, y1, x2, y2 = box.xyxy[0].cpu().numpy()
                        conf = float(box.conf[0].cpu())
                        bbox = [float(x1 / img_w), float(y1 / img_h), float(x2 / img_w), float(y2 / img_h)]
                        mask_b64 = ""
                        if result.masks is not None and i < len(result.masks):
                            mask_data = result.masks[i].data[0].cpu().numpy()
                            mask_binary = (mask_data > 0.5).astype(np.uint8)
                            mask_b64 = base64.b64encode(mask_binary.tobytes()).decode()
                        birds.append({"bbox": bbox, "confidence": conf, "mask": mask_b64})
            return {"birds": birds}
        finally:
            os.unlink(tmp_path)

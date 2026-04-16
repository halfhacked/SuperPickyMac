#!/usr/bin/env python3
"""Convert YOLO11l-seg bird detector to Core ML.

Input:  ~/projects/SuperPicky/models/yolo11l-seg.pt
Output: apps/mac-client/SuperPickyInference/Resources/Models/YOLOBirdDetector.mlpackage

CONVERSION NOTES (Phase 3 spike):
  - Direct ultralytics .export(format='coreml') fails on YOLO11 attention modules
    with coremltools 9.0: "only 0-dimensional arrays can be converted to Python scalars"
    (bug in coremltools/converters/mil/frontend/torch/ops.py _cast → _int).
  - Workaround: patch coremltools ops.py to call .item() before int() conversion.
  - nms=True is not supported for segmentation models — NMS is implemented in Swift.

OUTPUT FORMAT (from coremltools spec inspection):
  Input:
    image: ImageType 640×640 RGB (colorSpace=20), 1/255 scale baked in by ultralytics
  Outputs:
    var_2317: [1, 116, 8400] float32
      Layout: [batch, channel, anchor]
      Channels:  0:4  = bbox (cx, cy, w, h) in pixel coords relative to 640×640
                 4:84 = class scores (sigmoid already applied by YOLO11 head)
                84:116 = mask coefficients (32 values per anchor)
    var_2355: [1, 32, 160, 160] float32
      Mask prototypes: 32 prototype masks at 160×160 resolution

DECODING IN SWIFT:
  For each anchor i in 0..8400:
    bird_score = var_2317[0, 18, i]   (4 + birdClassID=14 = 18)
    Filter: bird_score > 0.25
    NMS: IoU threshold 0.45
    Mask: sigmoid(mask_coefs @ protos.reshape(32, 160*160)) > 0.5 → uint8[160*160]
    Un-letterbox: (cx - padLeft) / scale / origW  (for normalized [0,1] coords)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / 'projects/SuperPicky'))

from ultralytics import YOLO

MODEL_PATH = Path.home() / 'projects/SuperPicky/models/yolo11l-seg.pt'
OUTPUT_DIR = Path(__file__).parent.parent / 'apps/mac-client/SuperPickyInference/Resources/Models'
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

assert MODEL_PATH.exists(), f"Model not found: {MODEL_PATH}"

print(f"Loading YOLO model from {MODEL_PATH}")
model = YOLO(str(MODEL_PATH))

print("Exporting to Core ML...")
# Export to CoreML format
# nms=True: bake NMS into the model (simpler Swift code)
# imgsz=640: match training resolution
result = model.export(
    format='coreml',
    imgsz=640,
    nms=True,
    device='cpu',
)

print(f"Export result: {result}")

# ultralytics writes to the same directory as the .pt file
# Move the output to our Resources/Models directory
import shutil
src = Path(str(MODEL_PATH).replace('.pt', '.mlpackage'))
if not src.exists():
    src = Path(str(MODEL_PATH).replace('.pt', '_int8.mlpackage'))
if src.exists():
    dst = OUTPUT_DIR / 'YOLOBirdDetector.mlpackage'
    shutil.move(str(src), str(dst))
    print(f"Moved to: {dst}")
else:
    print(f"WARNING: Could not find exported mlpackage near {MODEL_PATH}")
    print(f"Result path was: {result}")

# Document the output format
try:
    import coremltools as ct
    mlmodel = ct.models.MLModel(str(OUTPUT_DIR / 'YOLOBirdDetector.mlpackage'))
    spec = mlmodel.get_spec()
    print("\n=== CoreML Model Spec ===")
    print("Inputs:")
    for i in spec.description.input:
        print(f"  {i.name}: {i}")
    print("Outputs:")
    for o in spec.description.output:
        print(f"  {o.name}: {o}")
except Exception as e:
    print(f"Could not inspect model: {e}")

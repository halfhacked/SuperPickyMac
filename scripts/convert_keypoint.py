#!/usr/bin/env python3
"""Convert ResNet50 PartLocalizer keypoint model to Core ML.

Input:  ~/projects/SuperPicky/models/cub200_keypoint_resnet50_slim.pth
Output: apps/mac-client/SuperPickyInference/Resources/Models/KeypointDetector.mlpackage

Model architecture (must match PartLocalizer in keypoint_detector.py exactly):
  ResNet50 backbone (fc replaced with Identity, in_features=2048)
  head: Linear(2048, 512) + BN1d(512) + ReLU + Dropout(0.2)
       + Linear(512, 256) + BN1d(256) + ReLU + Dropout(0.2)
  coord_head: Linear(256, 6) → sigmoid → reshape [batch, 3, 2]
  vis_head:   Linear(256, 3) → sigmoid

Input:  [1, 3, 416, 416] float32, ImageNet-normalized NCHW
Output: coords [1, 3, 2] float32 (left_eye xy, right_eye xy, beak xy in [0,1])
        vis    [1, 3]    float32 (left_eye_vis, right_eye_vis, beak_vis in [0,1])
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / 'projects/SuperPicky'))

import torch
import torch.nn as nn
import torchvision.models as models
import coremltools as ct
import numpy as np

MODEL_PATH = Path.home() / 'projects/SuperPicky/models/cub200_keypoint_resnet50_slim.pth'
OUTPUT_DIR = Path(__file__).parent.parent / 'apps/mac-client/SuperPickyInference/Resources/Models'
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

IMG_SIZE = 416


class PartLocalizer(nn.Module):
    """Exact copy of keypoint_detector.py PartLocalizer — must match training architecture."""
    def __init__(self, num_parts=3, hidden_dim=512, dropout=0.2):
        super().__init__()
        self.num_parts = num_parts
        self.backbone = models.resnet50(weights=None)
        in_features = self.backbone.fc.in_features  # 2048
        self.backbone.fc = nn.Identity()
        self.head = nn.Sequential(
            nn.Linear(in_features, hidden_dim),
            nn.BatchNorm1d(hidden_dim),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(hidden_dim, hidden_dim // 2),
            nn.BatchNorm1d(hidden_dim // 2),
            nn.ReLU(),
            nn.Dropout(dropout),
        )
        self.coord_head = nn.Linear(hidden_dim // 2, num_parts * 2)
        self.vis_head = nn.Linear(hidden_dim // 2, num_parts)

    def forward(self, x):
        features = self.head(self.backbone(x))
        coords = torch.sigmoid(self.coord_head(features)).view(-1, self.num_parts, 2)
        vis = torch.sigmoid(self.vis_head(features))
        return coords, vis


print(f"Loading weights from {MODEL_PATH}")
assert MODEL_PATH.exists(), f"Model not found: {MODEL_PATH}"

model = PartLocalizer()
model.eval()

checkpoint = torch.load(MODEL_PATH, map_location='cpu', weights_only=True)
if isinstance(checkpoint, dict) and 'model_state_dict' in checkpoint:
    model.load_state_dict(checkpoint['model_state_dict'])
    print("Loaded from checkpoint['model_state_dict']")
else:
    model.load_state_dict(checkpoint)
    print("Loaded from raw state dict")

torch.manual_seed(42)
example_input = torch.randn(1, 3, IMG_SIZE, IMG_SIZE)
with torch.no_grad():
    coords, vis = model(example_input)
print(f"coords shape: {coords.shape}, vis shape: {vis.shape}")
print(f"coords sample: {coords[0, 0].numpy()}")
print(f"vis sample:    {vis[0].numpy()}")

# Trace (Dropout is no-op in eval mode)
traced = torch.jit.trace(model, example_input)

# Verify trace
with torch.no_grad():
    tc, tv = traced(example_input)
assert torch.allclose(tc, coords, atol=1e-5), "Trace coords mismatch"
assert torch.allclose(tv, vis, atol=1e-5), "Trace vis mismatch"
print("Traced model verified ✓")

# Convert to Core ML with fp32 precision
print("Converting to Core ML...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input", shape=(1, 3, IMG_SIZE, IMG_SIZE), dtype=float)],
    outputs=[
        ct.TensorType(name="coords"),
        ct.TensorType(name="vis"),
    ],
    compute_units=ct.ComputeUnit.ALL,
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS14,
)

# Verify parity
test_input = example_input.numpy()
pred = mlmodel.predict({"input": test_input})
cml_coords = pred["coords"]  # shape depends on coremltools output
cml_vis = pred["vis"]
torch_coords = coords[0].detach().numpy()
torch_vis = vis[0].detach().numpy()

coords_delta = np.abs(cml_coords.reshape(-1) - torch_coords.reshape(-1)).max()
vis_delta = np.abs(cml_vis.reshape(-1) - torch_vis.reshape(-1)).max()
print(f"coords max delta: {coords_delta:.8f}")
print(f"vis max delta:    {vis_delta:.8f}")
assert coords_delta < 0.001, f"coords mismatch: {coords_delta}"
assert vis_delta < 0.001, f"vis mismatch: {vis_delta}"
print("CoreML parity verified ✓")

out_path = OUTPUT_DIR / 'KeypointDetector.mlpackage'
mlmodel.save(str(out_path))
print(f"\nSaved: {out_path}")
print("Next: xcrun coremlcompiler compile KeypointDetector.mlpackage Resources/Models/")

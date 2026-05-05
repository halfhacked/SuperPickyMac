#!/usr/bin/env python3
"""Convert EfficientNet-B3 flight classifier to Core ML.

Input:  ~/projects/SuperPicky/models/superFlier_efficientnet.pth
Output: app/SuperPickyInference/Resources/Models/FlightDetector.mlpackage

Model architecture (must match FlightDetector._build_model() exactly):
  EfficientNet-B3 backbone + Dropout(0.2) + Linear(in_features, 1) + Sigmoid
Input:  [1, 3, 384, 384] float32 (ImageNet-normalized, NCHW)
Output: [1, 1] float32 (sigmoid probability — is_flying = output > 0.5)
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path.home() / 'projects/SuperPicky'))

import torch
import torch.nn as nn
from torchvision import models
import coremltools as ct
import numpy as np

MODEL_PATH = Path.home() / 'projects/SuperPicky/models/superFlier_efficientnet.pth'
OUTPUT_DIR = Path(__file__).parent.parent / 'app/SuperPickyInference/Resources/Models'
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
OUTPUT_PATH = OUTPUT_DIR / 'FlightDetector.mlpackage'

IMAGE_SIZE = 384


def build_model():
    """Build model architecture — must match FlightDetector._build_model() exactly."""
    m = models.efficientnet_b3(weights=None)
    in_features = m.classifier[1].in_features  # 1536 for EfficientNet-B3
    m.classifier = nn.Sequential(
        nn.Dropout(0.2),
        nn.Linear(in_features, 1),
        nn.Sigmoid()
    )
    return m


print(f"Loading weights from {MODEL_PATH}")
assert MODEL_PATH.exists(), f"Model not found: {MODEL_PATH}"

model = build_model()
state_dict = torch.load(MODEL_PATH, map_location='cpu', weights_only=True)
model.load_state_dict(state_dict)
model.eval()

# Trace the model (Dropout is a no-op in eval mode → deterministic)
torch.manual_seed(42)
example_input = torch.randn(1, 3, IMAGE_SIZE, IMAGE_SIZE)
with torch.no_grad():
    example_output = model(example_input)
print(f"PyTorch output shape: {example_output.shape}, value: {example_output.item():.6f}")

traced = torch.jit.trace(model, example_input)

# Verify traced output matches original
with torch.no_grad():
    traced_out = traced(example_input)
assert abs(traced_out.item() - example_output.item()) < 1e-5, "Traced model mismatch"
print(f"Traced model verified ✓")

# Convert to Core ML
# Input is pre-normalized float32 NCHW — Swift wrapper handles resize + ImageNet norm
# Use FLOAT32 compute precision to minimize quantization error while still running on ANE.
print("Converting to Core ML...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(
        name="input",
        shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
        dtype=float,
    )],
    outputs=[ct.TensorType(name="output")],
    compute_units=ct.ComputeUnit.ALL,
    compute_precision=ct.precision.FLOAT32,  # avoid fp16 quantization error
    minimum_deployment_target=ct.target.macOS14,
)

# Verify CoreML output matches PyTorch
# fp32 CoreML should be within 1e-4; fp16 can drift ~0.02 (acceptable for binary classifiers)
test_input = example_input.numpy()
pred = mlmodel.predict({"input": test_input})
coreml_out = float(list(pred.values())[0].flatten()[0])
torch_out = example_output.item()
delta = abs(coreml_out - torch_out)
print(f"PyTorch output:  {torch_out:.8f}")
print(f"CoreML output:   {coreml_out:.8f}")
print(f"Delta:           {delta:.8f}")
# Classification decisions must agree (same side of 0.5 threshold)
torch_decision = torch_out > 0.5
coreml_decision = coreml_out > 0.5
assert torch_decision == coreml_decision, \
    f"Classification mismatch: torch={torch_decision}, coreml={coreml_decision}"
assert delta < 0.02, f"CoreML/PyTorch delta too large: {delta} (fp32 conversion should be < 0.02)"
print(f"CoreML parity verified ✓ (decision match, delta={delta:.6f})")

mlmodel.save(str(OUTPUT_PATH))
print(f"\nSaved: {OUTPUT_PATH}")
print("Next: xcrun coremlcompiler compile FlightDetector.mlpackage Resources/Models/")

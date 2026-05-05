#!/usr/bin/env python3
"""Convert OSEA ResNet34 bird species classifier to Core ML.

Input:  ~/projects/SuperPicky/models/model20240824.pth
Output: app/SuperPickyInference/Resources/Models/OSEAClassifier.mlpackage

Architecture: torchvision.models.resnet34(num_classes=11000)
  - Preprocessing: Resize(256) → CenterCrop(224) → ImageNet normalize
  - Output: 11000 logits (first 10964 are the valid OSEA species classes)

Uses /tmp/coreml-venv (Python 3.12 + coremltools 9.0 + PyTorch).
Must activate /tmp/coreml-venv before running:
    /tmp/coreml-venv/bin/python3 scripts/convert_osea.py
"""
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path.home() / 'projects/SuperPicky'))
sys.path.insert(0, str(Path.home() / 'projects/SuperPicky/birdid'))

MODEL_PATH = Path.home() / 'projects/SuperPicky/models/model20240824.pth'
OUTPUT_DIR = Path(__file__).parent.parent / 'app/SuperPickyInference/Resources/Models'
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

assert MODEL_PATH.exists(), f"Model not found: {MODEL_PATH}"

import torch
import torchvision.models as models

print(f"Loading OSEA ResNet34 from {MODEL_PATH}")

# Load checkpoint using the same logic as osea_classifier.py
loaded = torch.load(str(MODEL_PATH), map_location='cpu', weights_only=False)

def extract_state_dict(obj):
    if isinstance(obj, dict):
        if 'state_dict' in obj: return obj['state_dict']
        if 'model_state_dict' in obj: return obj['model_state_dict']
        return obj
    if isinstance(obj, torch.nn.Module):
        return obj.state_dict()
    raise TypeError(f"Unexpected checkpoint type: {type(obj)}")

model = models.resnet34(num_classes=11000)
state_dict = extract_state_dict(loaded)
model.load_state_dict(state_dict)
model.eval()

print(f"Model loaded. Output size: {model.fc.out_features}")

# Convert to CoreML
import coremltools as ct

# Trace with a 224×224 RGB input (after center crop)
example = torch.zeros(1, 3, 224, 224)
with torch.no_grad():
    traced = torch.jit.trace(model, example)

# Define input as ImageType with ImageNet normalization baked in
input_type = ct.ImageType(
    name='image',
    shape=(1, 3, 224, 224),
    scale=1.0 / (255.0 * 0.226),   # approximate: use bias instead
    bias=[-0.485 / 0.229, -0.456 / 0.224, -0.406 / 0.225],
    color_layout=ct.colorlayout.RGB,
    channel_first=True,
)

# Actually, bake in proper per-channel normalization via ct.convert preprocessing
# mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225]
# scale = 1/255, bias = -mean/std
MEAN = [0.485, 0.456, 0.406]
STD  = [0.229, 0.224, 0.225]

# CoreML ImageType: pixel_value = (raw_pixel / 255 - mean) / std
#                              = raw_pixel * (1/255/std) - mean/std
# Use per-channel scale+bias is not directly supported; use TensorType + manual norm
# Instead, use the simple approach: pass a MultiArray input, do normalization in Swift

# Simpler: export with TensorType input, do preprocessing in Swift (same as FlightModel)
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name='input', shape=(1, 3, 224, 224))],
    convert_to='mlprogram',
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS14,
)

dst = OUTPUT_DIR / 'OSEAClassifier.mlpackage'
mlmodel.save(str(dst))
print(f"Saved to {dst}")

# Inspect outputs
spec = mlmodel.get_spec()
print("Outputs:")
for o in spec.description.output:
    print(f"  {o.name}: {o}")

# Verify numerical parity with PyTorch
print("\nVerifying parity...")
import PIL.Image

# Test with a random image
test_image = np.random.randint(0, 255, (256, 256, 3), dtype=np.uint8)
pil_img = PIL.Image.fromarray(test_image, 'RGB')

from torchvision import transforms
transform = transforms.Compose([
    transforms.Resize(256),
    transforms.CenterCrop(224),
    transforms.ToTensor(),
    transforms.Normalize(mean=MEAN, std=STD),
])
tensor = transform(pil_img).unsqueeze(0)

with torch.no_grad():
    torch_out = model(tensor)[0].numpy()

# CoreML: pass the normalized tensor directly (TensorType input)
coreml_input = tensor.numpy()
coreml_result = mlmodel.predict({'input': coreml_input})
output_name = list(coreml_result.keys())[0]
coreml_out = coreml_result[output_name].flatten()

delta = np.abs(torch_out - coreml_out).max()
print(f"Max delta PyTorch vs CoreML: {delta:.2e}")
assert delta < 1e-3, f"Parity check failed: delta={delta}"
print("Parity OK")

#!/usr/bin/env python3
"""Convert TOPIQ/CFANet aesthetics model to Core ML.

Input:  ~/projects/SuperPicky/models/cfanet_iaa_ava_res50-3cd62bb3.pth
Output: app/SuperPickyInference/Resources/Models/AestheticsModel.mlpackage

Architecture: CFANet (ResNet50 backbone + Transformer cross-attention)
  - Input: 384×384 RGB (normalized to [0,1] in forward pass)
  - Output: MOS score (1-10 range) or probability distribution (10 classes)

Run with:
    /tmp/coreml-venv/bin/python3 scripts/convert_topiq.py
"""
import sys
from pathlib import Path
import numpy as np

# Add SuperPicky project paths
sys.path.insert(0, str(Path.home() / 'projects/SuperPicky'))
sys.path.insert(0, str(Path.home() / 'projects/SuperPicky/birdid'))

MODEL_PATH = Path.home() / 'projects/SuperPicky/models/cfanet_iaa_ava_res50-3cd62bb3.pth'
OUTPUT_DIR = Path(__file__).parent.parent / 'app/SuperPickyInference/Resources/Models'
OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

assert MODEL_PATH.exists(), f"Model not found: {MODEL_PATH}"

import torch
import torch.nn.functional as F

# Patch config.py so it doesn't need a full UI environment
import types
config_mod = types.ModuleType('config')
config_mod.get_best_device = lambda: torch.device('cpu')
sys.modules['config'] = config_mod

# Patch i18n
i18n_mod = types.ModuleType('tools.i18n')
i18n_mod.t = lambda key, **kwargs: key
tools_mod = types.ModuleType('tools')
sys.modules['tools'] = tools_mod
sys.modules['tools.i18n'] = i18n_mod

from topiq_model import CFANet, load_topiq_weights
import torch.nn.functional as F_orig

# Patch F.interpolate: replace bicubic with bilinear for CoreML compatibility.
# The only bicubic call in CFANet is for positional embedding interpolation (line 372)
# where the quality difference is negligible.
_orig_interpolate = F_orig.interpolate
def _patched_interpolate(input, size=None, scale_factor=None, mode='nearest',
                          align_corners=None, recompute_scale_factor=None, antialias=False):
    if mode == 'bicubic':
        mode = 'bilinear'
        if align_corners is None:
            align_corners = False
    return _orig_interpolate(input, size=size, scale_factor=scale_factor, mode=mode,
                              align_corners=align_corners,
                              recompute_scale_factor=recompute_scale_factor,
                              antialias=antialias)

import torch.nn.functional as F_topiq_module
import topiq_model
topiq_model.F.interpolate = _patched_interpolate

print(f"Loading CFANet from {MODEL_PATH}")
model = CFANet()
load_topiq_weights(model, str(MODEL_PATH), torch.device('cpu'))
model.eval()

# Test with 384×384 input
INPUT_SIZE = 384
example = torch.zeros(1, 3, INPUT_SIZE, INPUT_SIZE)
with torch.no_grad():
    out = model(example, return_mos=True)
print(f"PyTorch forward OK. Output shape: {out.shape}, value: {out.item():.4f}")

# Wrap to always return distribution (10 values) instead of MOS scalar
class CFANetWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        # Return the 10-class probability distribution
        dist = self.model(x, return_mos=False, return_dist=True)
        return dist

wrapper = CFANetWrapper(model)
wrapper.eval()

print("Tracing model...")
with torch.no_grad():
    traced = torch.jit.trace(wrapper, example)

test_out = traced(example)
print(f"Traced output shape: {test_out.shape}")

print("Converting to CoreML...")
import coremltools as ct

mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name='input', shape=(1, 3, INPUT_SIZE, INPUT_SIZE))],
    convert_to='mlprogram',
    compute_precision=ct.precision.FLOAT32,
    minimum_deployment_target=ct.target.macOS14,
)

dst = OUTPUT_DIR / 'AestheticsModel.mlpackage'
mlmodel.save(str(dst))
print(f"Saved to {dst}")

spec = mlmodel.get_spec()
print("Outputs:")
for o in spec.description.output:
    print(f"  {o.name}: shape={list(o.type.multiArrayType.shape)}")

# Parity check
print("\nVerifying parity...")
test_img = np.random.rand(1, 3, INPUT_SIZE, INPUT_SIZE).astype(np.float32)
test_tensor = torch.from_numpy(test_img)

with torch.no_grad():
    torch_dist = wrapper(test_tensor).numpy().flatten()

output_name = list(mlmodel.predict({'input': test_img}).keys())[0]
coreml_dist = mlmodel.predict({'input': test_img})[output_name].flatten()

delta = np.abs(torch_dist - coreml_dist).max()
print(f"Max delta: {delta:.2e}")

# Compute MOS from distribution for both
mos_torch  = float(sum((i+1) * torch_dist[i] for i in range(10)))
mos_coreml = float(sum((i+1) * coreml_dist[i] for i in range(10)))
print(f"MOS PyTorch: {mos_torch:.4f}, CoreML: {mos_coreml:.4f}")
assert abs(mos_torch - mos_coreml) < 0.01, f"MOS delta too large: {abs(mos_torch-mos_coreml)}"
print("Parity OK")

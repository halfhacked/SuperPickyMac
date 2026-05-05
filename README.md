# SuperPicky Mac

AI-powered bird photo culling — native macOS app.

SuperPicky Mac is a native macOS port of **[SuperPicky](https://gitcode.com/Jamesphotography/SuperPicky)** by [Jamesphotography](https://gitcode.com/Jamesphotography). See [Credits](#credits) below.

## Requirements

- macOS 14 Sonoma or later
- Apple Silicon recommended
- 8GB RAM minimum
- Xcode 15+ (for Swift 5.10)

## Getting Started

```bash
# Build
cd app
xcodebuild build -scheme SuperPicky -destination 'platform=macOS'

# Run
open ~/Library/Developer/Xcode/DerivedData/SuperPicky-*/Build/Products/Debug/SuperPicky.app

# Test (L1 unit)
xcodebuild test -scheme SuperPicky -destination 'platform=macOS' -only-testing:SuperPickyTests
```


## Credits

SuperPicky Mac is derived from and builds on [**SuperPicky**](https://gitcode.com/Jamesphotography/SuperPicky) by [Jamesphotography](https://gitcode.com/Jamesphotography). The upstream Python project is the source of this Mac port's core photo-culling approach, and we gratefully acknowledge that work.

Components that originated in upstream SuperPicky:

- **CoreML model weights** — all five inference models are converted from the original SuperPicky training checkpoints. Weights are mirrored at [Airdreamer/SuperPicky-models](https://huggingface.co/Airdreamer/SuperPicky-models) on Hugging Face. See [Individual models](#individual-models) below for the architecture and upstream origin of each.
- **Rating engine and thresholds** — the photo-rating algorithm, Tenengrad sharpness scoring, ISO normalization, focus-point detection, burst grouping via perceptual hashing, and the full `CullingConfig` parameter surface are ported from upstream SuperPicky.

### Individual models

The five CoreML models shipped with SuperPicky Mac are built on the following upstream architectures and checkpoints. The SuperPicky Mac port converts the trained weights to CoreML via the scripts in `tools/model-conversion/`; it does not retrain.

- **Flight classifier** — `FlightDetector.mlpackage` (`FlightModel.swift`). Architecture: **EfficientNet-B3** ([Tan & Le, 2019](https://arxiv.org/abs/1905.11946)) with a custom `Dropout(0.2) + Linear + Sigmoid` head. Upstream checkpoint: `superFlier_efficientnet.pth` (SuperPicky).
- **Keypoint detector** — `KeypointDetector.mlpackage` (`KeypointModel.swift`). Architecture: **ResNet50** ([He et al., 2016](https://arxiv.org/abs/1512.03385)) backbone with a custom `PartLocalizer` head (2-layer MLP + separate coord / visibility heads). Trained on the **[CUB-200-2011](https://www.vision.caltech.edu/datasets/cub_200_2011/)** dataset ([Wah et al.](https://authors.library.caltech.edu/records/cvm3y-5hh21)). Upstream checkpoint: `cub200_keypoint_resnet50_slim.pth` (SuperPicky).
- **Bird detector** — `YOLOBirdDetector.mlpackage` (`YOLOBirdDetector.swift`). Architecture: **YOLO11l-seg** by [Ultralytics](https://github.com/ultralytics/ultralytics) (AGPL-3.0). Upstream checkpoint: `yolo11l-seg.pt`.
- **Species classifier (OSEA)** — `OSEAClassifier.mlpackage` (`OSEAClassifier.swift`). Architecture: **ResNet34** ([He et al., 2016](https://arxiv.org/abs/1512.03385)) with a 11000-way classification head (first 10964 classes are valid species). Based on **[OSEA](https://github.com/sun-jiao/osea)** by [sun-jiao](https://github.com/sun-jiao) — the open-source bird-species recognition project that provides the model architecture and training pipeline used by upstream SuperPicky. Upstream checkpoint: `model20240824.pth` (SuperPicky).
- **Aesthetics model** — `AestheticsModel.mlpackage` (`AestheticsModel.swift`). Architecture: **CFANet / TOPIQ** ([Chen et al., 2023](https://arxiv.org/abs/2308.03060)) — ResNet50 backbone with transformer cross-attention for image-quality assessment. Trained on the **[AVA](https://ieeexplore.ieee.org/document/6247954)** ([Murray et al., 2012](https://ieeexplore.ieee.org/document/6247954)) aesthetic-visual-analysis dataset. Upstream checkpoint: `cfanet_iaa_ava_res50-3cd62bb3.pth` (SuperPicky).

If you use SuperPicky Mac in your work, please credit both SuperPicky Mac and the upstream SuperPicky project, and — where applicable — the specific model architecture and dataset authors listed above.

## License

GPL-3.0

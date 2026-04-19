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
cd apps/mac-client
swift build

# Run
swift run SuperPicky

# Test
swift test
```


## Credits

SuperPicky Mac is derived from and builds on [**SuperPicky**](https://gitcode.com/Jamesphotography/SuperPicky) by [Jamesphotography](https://gitcode.com/Jamesphotography). The upstream Python project is the source of this Mac port's core photo-culling approach, and we gratefully acknowledge that work.

Components that originated in upstream SuperPicky:

- **CoreML model weights** — the flight classifier, keypoint detector, YOLO bird detector, OSEA species classifier, and aesthetics model are converted from the original SuperPicky models (weights mirrored at [Airdreamer/SuperPicky-models](https://huggingface.co/Airdreamer/SuperPicky-models) on Hugging Face).
- **Rating engine and thresholds** — the photo-rating algorithm, Tenengrad sharpness scoring, ISO normalization, focus-point detection, burst grouping via perceptual hashing, and the full `CullingConfig` parameter surface are ported from upstream SuperPicky.

If you use SuperPicky Mac in your work, please also credit the original SuperPicky project.

## License

GPL-3.0

# SuperPicky Mac

AI-powered bird photo culling — native macOS app.

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

## Python Inference Server

```bash
cd python-server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
python superpicky_server.py --port 8420
```

## License

GPL-3.0

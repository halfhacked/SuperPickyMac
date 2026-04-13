# SuperPicky Mac

Native macOS app for AI-powered bird photo culling.

## Architecture

- Swift/SwiftUI frontend (all UI + business logic)
- Python HTTP server (model inference only — 5 endpoints)
- GRDB for SQLite persistence
- Vision/Accelerate/Core Image for image processing

## Quality System

| Layer | What | Command | Trigger |
|-------|------|---------|---------|
| G1 Static | swift build + flake8 | `scripts/pre-commit.sh` | pre-commit |
| L1 Unit | Swift Testing + pytest (mocked) | `scripts/pre-commit.sh` | pre-commit |
| L2 Integration | Swift ↔ real Python server | `scripts/run-l2.sh` | pre-push |
| G2 Security | gitleaks | `scripts/gate-security.sh` | pre-push |
| L3 BDD | XCUITest full user flows | `scripts/run-l3.sh` | on-demand |

## Port Convention

| Environment | Port |
|-------------|------|
| Dev | 8420 |
| L2 Integration | 18420 |
| L3 BDD | 28420 |

## Common Commands

```bash
# Build
cd apps/mac-client && swift build

# Test
cd apps/mac-client && swift test

# Python server (dev)
cd python-server && python superpicky_server.py --port 8420

# Python server tests
cd python-server && pytest tests/ -v
```

## Key Decisions

- InferenceClient protocol abstracts Python HTTP vs future CoreML
- One .report.db per processed folder
- Python server is inference-only — no business logic
- All business logic (rating, burst, exposure, sharpness) in Swift
- CullingConfig is @MainActor @Observable (UI state)
- Fixed minimums (sharpness 100, aesthetics 2.0) separate from configurable thresholds

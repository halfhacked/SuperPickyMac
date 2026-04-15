# Native Inference Rewrite — Design

**Status:** Design approved, ready for implementation plan
**Date:** 2026-04-15
**Scope:** Replace the entire Python inference stack (`python-server/` + dependency on `birdpreen` at runtime + dependency on legacy `~/projects/SuperPicky/core/`) with native Swift code running Core ML models in-process.

## Goals

The user chose *all of the above* when asked what's driving the rewrite:

1. **Shipping** — a single signed `.app` bundle. No Python interpreter, no venv, no model-download dance, no `birdpreen` PyPI install on the user's machine.
2. **Performance** — native Core ML with Neural Engine acceleration; eliminate HTTP, JPEG re-encode, temp-file round-trip, Flask overhead.
3. **Offline / bundled** — no runtime dependency on `~/projects/SuperPicky/` or `birdpreen`. Everything SuperPicky needs is either in the app bundle or downloaded once on first launch.
4. **Willing to accept a multi-week phased rewrite.**

## Non-goals

- Rewriting `preen` itself. `preen` stays a separate Python project with its own Photos-library-tagging CLI. This rewrite removes SuperPicky's *runtime* dependency on it; preen continues to exist as a reference blueprint and a sibling tool.
- Changing model architectures except where a model refuses to convert to Core ML (TOPIQ is the only known risk area, isolated in Phase 5).
- Changing thresholds, rating logic, or any user-visible behavior. **Exception:** if Phase 5 Path B ships a TOPIQ replacement whose score range differs from TOPIQ's, `RatingEngine` aesthetics thresholds (`minimumAesthetics` and `config.aestheticsThreshold`) will be recalibrated in the same PR so that the star-rating distribution on a reference 200-photo folder is preserved within ≤5% photos shifting by ≤1 star. This is the only pre-authorized change to user-visible behavior.
- Shipping new features. Any new culling features requested during the migration are out of scope and should branch from `main` independently.
- Offline first-launch. Users must connect to the internet once to download models.
- Intel Mac support. See Hardware requirements above.

---

## Acceptance criteria

The rewrite is done when **all** of these are true:

1. `HTTPInferenceClient.swift`, `ProcessManager.swift`, `python-server/` directory, and all Python-related scripts/config are deleted from the repo.
2. `CoreMLInferenceClient` is the sole implementation of the `InferenceClient` protocol in production.
3. `swift build`, `swift test`, `scripts/run-l2.sh`, `scripts/run-l3.sh` all pass on CI with zero references to Flask, torch, ultralytics, or preen runtime.
4. Parity Gate #1: every endpoint parity test green against the curated fixture set at the tolerances defined in Section 6.
5. Parity Gate #2: on a 200-photo real-folder run routed through both backends, (a) strict rating match ≥ 90%, (b) relaxed rating match (±1 star) ≥ 98%, (c) species top-1 match ≥ 95% on photos where both runs identified a species, (d) identification rate agreement within ±2%, (e) mean absolute rating difference ≤ 0.1, (f) pick-rate agreement (5-star count) within ±2% of the total photo count.
6. Starting the app on a machine with no Python installed AND with network connectivity produces a functional app after first-launch model download completes. Processing a folder works end-to-end. **Offline first-launch is explicitly unsupported** — a user who opens the app for the first time without network connectivity sees an error sheet with a "Retry when connected" button and no functional processing until models are downloaded.
7. The shipped `.app` contains no embedded Python interpreter, no venv, no `.pth` files.
8. On a model-cache-warm cold launch (models already downloaded), the app reaches "ready to process folder" within ~1 second on a baseline M1 MacBook Air. Expected budget: Bundle + AppDelegate + MainView first paint ~350 ms + `CoreMLInferenceClient.init` ~330 ms (budget 400 ms) + GRDB handle open ~20 ms + first-paint render ~50 ms. Total **~750 ms expected (budget ~820 ms)**; headroom for cold disk. This is a target, not a contract.

## Hardware requirements

- **Apple Silicon only** (M1 or newer). Core ML on Intel Macs runs on CPU only (no Neural Engine), which nullifies Goal #2 (performance). The whole premise of the rewrite is ANE acceleration.
- **Minimum macOS 14** (unchanged from today's `Package.swift` declaration). Core ML API surface used assumes macOS 14+.
- **Minimum 8 GB unified memory** — justified in Section 5 "Memory budget" subsection. Smaller configs work but may trigger Jetsam pressure during full-folder runs.
- **≥ 500 MB free disk** in `~/Library/Application Support/com.superpicky.mac/ModelCache/` for models + species databases.
- **Network required for first launch** (one time, ~350 MB total download; ~310 MB compressed models + ~40 MB compressed species data). Installed footprint ~450 MB. Subsequent launches are fully offline.

Phase 7 of the rollout adds an `.arm64`-only `ARCHS` setting to the Xcode project so Intel Macs can't even install the native-path builds; the HTTP-path builds (still available via a legacy branch tag — see Section 7 Phase 6) continue to work on both.

---

## Design decisions

| Decision | Choice | Rationale |
|---|---|---|
| Motivation | All four (shipping, performance, offline, multi-week OK) | User selected option 4 |
| preen ownership | User owns `~/projects/preen` | Makes preen a readable blueprint rather than a black-box dependency |
| Migration strategy | Dual-track via the existing `InferenceClient` protocol, with a Settings toggle | Lowest risk; `InferenceClient` was designed for this. Allows A/B parity validation before flipping default. |
| Parity tolerance | Strict parity on YOLO / OSEA / keypoint / flight (standard CNNs, clean conversion). TOPIQ swappable if it refuses to convert. | Isolates the one legitimate schedule risk without compromising species/sharpness correctness. |
| Model distribution | Download on first launch from `manifest.json` hosted on HuggingFace/CDN, verified by SHA-256, cached in `~/Library/Application Support/com.superpicky.mac/ModelCache/` | Keeps the app download small; decouples model updates from app updates |
| Phasing | Easiest → hardest: Flight → Keypoint → YOLO → OSEA → TOPIQ → flip default → kill Python | De-risks tooling (model conversion, parity harness, download path) with low-stakes model first |
| Parity validation | Gate #1 (per-endpoint numerical parity as PR gate) + Gate #2 (end-to-end rating parity as phase gate) | Gate #1 catches per-model regressions; Gate #2 catches cross-model interaction bugs |
| Code location | New SPM sub-target `SuperPickyInference` alongside `SuperPickyApp` in the same package | Pure-logic module, zero AppKit imports, fast to compile and test |
| Concurrency | `CoreMLInferenceClient` is `@unchecked Sendable`, not an actor; `MLModel` is thread-safe by Apple's documented design | Preserves `PipelineCoordinator`'s `async let` parallelism in the aesthetics/keypoint/flight fan-out |
| Pinyin generation | Pre-compute at packaging time using `pypinyin`, ship as a column in `bird_reference.sqlite` | Swift has no native pypinyin; runtime implementation would require bundling a Han→pinyin table |
| RAW decode unification | Use Swift's existing `RAWConverter` for all endpoints (native) | Native path unifies RAW decode, which is *more* consistent than today's mixed rawpy/Swift pipeline |

---

## Section 1 — Code organization

New SPM sub-target `SuperPickyInference` in the existing package, alongside `SuperPickyApp`.

```
apps/mac-client/
├── Package.swift                       # add SuperPickyInference target
├── SuperPickyInference/               # NEW — pure-logic, no UI, no AppKit
│   ├── CoreMLInferenceClient.swift
│   ├── Models/
│   │   ├── YOLOBirdDetector.swift
│   │   ├── OSEAClassifier.swift
│   │   ├── KeypointModel.swift
│   │   ├── FlightModel.swift
│   │   └── AestheticsModel.swift
│   ├── Pipeline/
│   │   ├── SmartCrop.swift
│   │   ├── SpeciesFilterChain.swift
│   │   ├── AvonetFilter.swift
│   │   └── RegionBounds.swift
│   ├── Data/
│   │   ├── SpeciesDatabase.swift
│   │   ├── GPSExtractor.swift
│   │   └── RAWLoader.swift
│   └── Download/
│       ├── ModelManager.swift
│       └── ModelManifest.swift
├── SuperPickyApp/
│   ├── InferenceClient.swift           # protocol stays here (unchanged)
│   ├── HTTPInferenceClient.swift       # stays until kill-Python phase (Phase 7)
│   ├── PipelineCoordinator.swift       # unchanged — consumes the protocol
│   ├── Settings/InferenceBackendSetting.swift  # NEW — dual-track toggle UI
│   └── ...
└── SuperPickyTests/
    ├── Inference/                      # NEW — native inference L1 unit tests
    │   ├── SmartCropTests.swift
    │   ├── OSEAClassifierTests.swift
    │   ├── SpeciesFilterChainTests.swift
    │   ├── AvonetFilterTests.swift
    │   └── ...
    └── Parity/                         # NEW — L2 parity harness (gates #1 and #2)
        ├── ParityTestBase.swift
        ├── EndpointParityTests.swift
        ├── RatingParityTests.swift
        ├── Fixtures/                   # ~30 real photos (git-lfs)
        └── ExpectedOutputs/            # Golden-file snapshots
```

**What does NOT change:**
- `InferenceClient.swift` protocol — unchanged, same methods, same response types
- `HTTPInferenceClient.swift` — stays exactly as-is during the migration; deleted only in Phase 7
- `PipelineCoordinator.swift` — unchanged; only knows about the protocol
- `DetectionResult.swift` response structs — unchanged (both clients emit the same types)

**Per CLAUDE.md retrospective:** new Swift files must be added to both `Package.swift` AND the `.xcodeproj`. Every file-creation commit in the plan will explicitly list xcodeproj updates.

---

## Section 2 — `CoreMLInferenceClient` structure

```swift
// SuperPickyInference/CoreMLInferenceClient.swift
public final class CoreMLInferenceClient: InferenceClient, @unchecked Sendable {
    private let modelManager: ModelManager
    private let yoloModel: YOLOBirdDetector
    private let oseaModel: OSEAClassifier
    private let keypointModel: KeypointModel
    private let flightModel: FlightModel
    private let aestheticsModel: AestheticsModel
    private let speciesDB: SpeciesDatabase
    private let avonet: AvonetFilter
    private let rawLoader: RAWLoader
    private let gpsExtractor: GPSExtractor

    public init(modelManager: ModelManager) async throws {
        self.modelManager = modelManager
        let paths = try modelManager.resolvedPaths()
        self.yoloModel = try YOLOBirdDetector(url: paths.yolo)
        self.oseaModel = try OSEAClassifier(url: paths.osea)
        self.keypointModel = try KeypointModel(url: paths.keypoint)
        self.flightModel = try FlightModel(url: paths.flight)
        self.aestheticsModel = try AestheticsModel(url: paths.aesthetics)
        self.speciesDB = try SpeciesDatabase(url: paths.speciesDB)
        self.avonet = try AvonetFilter(
            avonetDBURL: paths.avonetDB,
            ebirdMappingURL: paths.ebirdMapping,
            offlineDataDir: paths.offlineData
        )
        self.rawLoader = RAWLoader()
        self.gpsExtractor = GPSExtractor()
    }

    public func detect(image: CGImage) async throws -> DetectionResult {
        try await yoloModel.detect(image: image)
    }

    public func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        try await aestheticsModel.score(image: image)
    }

    public func keypoints(image: CGImage) async throws -> KeypointResult {
        try await keypointModel.predict(image: image)
    }

    public func flight(image: CGImage) async throws -> FlightResult {
        try await flightModel.predict(image: image)
    }

    public func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        let url = URL(fileURLWithPath: filePath)
        let image = try rawLoader.load(url: url)
        let gps = try? gpsExtractor.extract(url: url)

        let birdBoxes = try await yoloModel.detectBirds(image: image)
        let filterChain = try avonet.buildFilterChain(
            lat: gps?.latitude,
            lon: gps?.longitude
        )

        var results: [SpeciesMatch] = []
        for box in birdBoxes {
            let crop = SmartCrop.crop(image: image, box: box)
            let logits = try await oseaModel.logits(
                image: crop,
                preprocessing: .directResize
            )
            if let best = try SpeciesFilterChain.bestMatch(
                logits: logits,
                filters: filterChain,
                regionalThreshold: 80.0,
                globalThreshold: 90.0,
                temperature: 0.9,
                speciesDB: speciesDB
            ) {
                results.append(best)
            }
        }
        return IdentifyResponse(
            species: Array(results.prefix(topK)),
            birds: birdBoxes.map { $0.asBirdDetection(imageSize: image.size) },
            totalDetected: birdBoxes.count
        )
    }

    public func healthCheck() async throws -> ServerHealth {
        return ServerHealth(
            status: "ready",
            modelsLoaded: ["yolo", "osea", "keypoint", "flight", "aesthetics"],
            device: MLDevice.current.rawValue,
            version: "native-1.0.0"
        )
    }
}
```

**Key design choices:**

| Decision | Choice | Rationale |
|---|---|---|
| Constructor | `async throws init` that takes a ready `ModelManager` | Client cannot be instantiated before models exist on disk. Forces the model-download gate at app startup, not mid-pipeline. |
| Threading | `@unchecked Sendable`, no actor isolation | `MLModel.prediction(...)` is thread-safe per Apple's docs; preserves `PipelineCoordinator`'s `async let` parallelism. No locks, no queues. |
| Preprocessing | Each wrapper owns its preprocessing | Each model has its own input size, normalization, interpolation — coupling preprocessing to the model avoids a leaky central helper |
| `identify()` | Orchestrates YOLO + SmartCrop + OSEA + SpeciesFilterChain inline | One-pass, same data flow as `preen/detector.py`; easier to verify via side-by-side read with Python source |
| `healthCheck()` | Synthesized, never fails for connectivity reasons | The old impl returned server-ready status; native always returns ready if models loaded. Keeps protocol consumers happy. |
| TTA (h-flip averaging) | Implemented in `OSEAClassifier.logits()` via two `MLMultiArray` inferences + elementwise average | Matches `osea_classifier.py:_infer_with_tta` exactly |
| Temperature softmax + species masking | Done in Swift on raw logits | Same place the Python version does it (`predict_from_logits`) |
| RAW loading | `RAWLoader` wraps existing Swift `RAWConverter` | Swift already has native RAW decode via `CGImageSource`; no new dependency |
| GPS extraction | `CGImageSourceCopyPropertiesAtIndex` with `kCGImagePropertyGPSDictionary` | Zero dependencies |

**Threading note.** The Apple Neural Engine has a hardware-level queue; concurrent `prediction()` calls routed to ANE serialize at the silicon level. This is not a correctness issue, but it affects the optimal `MLModelConfiguration.computeUnits` choice per model. The plan includes a micro-benchmark commit per phase to pin the best setting.

**Fresh-buffer rule.** `MLModel.prediction(...)` is thread-safe per Apple's docs, but `MLMultiArray` and `MLFeatureProvider` instances are not. Each model wrapper's `predict()` method **must allocate a fresh input buffer on every call** — no cached-and-reused `MLMultiArray` across concurrent callers. Cache the `MLModel` instance; allocate everything else per call. A unit test asserts that the wrappers don't hold on to mutable input references after init.

**Compute-unit configuration.** Each model wrapper's initializer takes an `MLModelConfiguration` parameter (defaulting to `.all`) so the compute unit choice is part of the wrapper's public API, not hidden inside. The phase-end micro-benchmark commits write the best-measured setting into a `ModelConfiguration` constants file; the client reads from that constant at init time. This keeps the tuning results visible in git history rather than buried in a private property.

```swift
public final class YOLOBirdDetector: Sendable {
    public init(url: URL, configuration: MLModelConfiguration = .default) throws { ... }
}

// ModelConfiguration.swift — output of per-model benchmark commits
public enum ModelConfiguration {
    public static let yolo: MLModelConfiguration = {
        let c = MLModelConfiguration()
        c.computeUnits = .cpuAndGPU  // measured best on M1; ANE serializes with OSEA
        return c
    }()
    public static let osea: MLModelConfiguration = {
        let c = MLModelConfiguration()
        c.computeUnits = .all  // OSEA is the biggest — owns the ANE
        return c
    }()
    // ... keypoint, flight, aesthetics
}
```

**healthCheck failure semantics.** The native `healthCheck()` returns ready if all five model wrappers initialized and the species databases opened successfully. That's it. If a model later fails a `prediction()` call mid-pipeline (transient ANE error, OS memory pressure killing a worker, etc.), the error bubbles up through `identify()` / `detect()` / etc. as `InferenceError.requestFailed(statusCode: -1)` with an associated underlying error. The `PipelineCoordinator`'s existing per-photo error path catches it, logs via `os.Logger`, sets `photo.starRating = 0`, and continues processing the next photo. No "server is down" state exists because there is no server.

**MockInferenceClientForUI adaptation.** The existing mock conforms to `InferenceClient` and returns deterministic fake data for UI preview rendering. It is backend-agnostic — no HTTP assumptions. It continues to work unchanged after Phase 7. A new `MockCoreMLInferenceClient` is **not** introduced because it would be a strictly less useful version of `MockInferenceClientForUI` (same protocol, same method shapes). Tests that need to exercise the real native path use the real `CoreMLInferenceClient` with a pre-staged model cache (via `ModelManager.preloadedReadyInstance(at:)` described in Section 3).

**What the native path explicitly drops:**
- The Swift-side JPEG re-encode that happens 4× per photo in `HTTPInferenceClient.jpegData(...)`
- Flask's multipart parsing and the tempfile write/unlink cycle inside each Python handler
- The `/identify` image-bytes fallback (only used by deleted Python tests)

---

## Section 3 — Model download manager

### Manifest

Bundled in the app at build time. Source of truth for "ready."

```json
{
  "version": 1,
  "models": [
    {
      "id": "yolo11l-seg",
      "filename": "yolo11l-seg.mlmodelc.zip",
      "url": "https://huggingface.co/halfhacked/superpicky-models/resolve/v1.0.0/yolo11l-seg.mlmodelc.zip",
      "sha256": "<filled at packaging time>",
      "sizeBytes": 58720256,
      "installPath": "Models/yolo11l-seg.mlmodelc"
    },
    {
      "id": "osea-resnet34",
      "filename": "osea_resnet34_v20240824.mlmodelc.zip",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 113246208,
      "installPath": "Models/osea_resnet34.mlmodelc"
    },
    {
      "id": "keypoint-resnet50",
      "filename": "cub200_keypoint_resnet50.mlmodelc.zip",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 98000000,
      "installPath": "Models/keypoint_resnet50.mlmodelc"
    },
    {
      "id": "flight-efficientnet",
      "filename": "superflier_efficientnet.mlmodelc.zip",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 12000000,
      "installPath": "Models/flight_efficientnet.mlmodelc"
    },
    {
      "id": "aesthetics",
      "filename": "aesthetics_v1.mlmodelc.zip",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 40000000,
      "installPath": "Models/aesthetics.mlmodelc"
    },
    {
      "id": "bird-reference-db",
      "filename": "bird_reference.sqlite.gz",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 2500000,
      "installPath": "Data/bird_reference.sqlite"
    },
    {
      "id": "avonet-db",
      "filename": "avonet.db.gz",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 40000000,
      "installPath": "Data/avonet.db"
    },
    {
      "id": "ebird-mapping",
      "filename": "ebird_classid_mapping.json.gz",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 50000,
      "installPath": "Data/ebird_classid_mapping.json"
    },
    {
      "id": "ebird-region-lists",
      "filename": "offline_ebird_data.tar.gz",
      "url": "...",
      "sha256": "...",
      "sizeBytes": 5000000,
      "installPath": "Data/offline_ebird_data/"
    }
  ]
}
```

**Why the manifest is bundled, not fetched:** it's covered by the signed `.app`, so model updates require an app update. Eliminates trust-bootstrapping problems.

**Why `.mlmodelc.zip`:** Core ML's on-disk format is a directory, not a file. Compile `.mlmodel` → `.mlmodelc` at packaging time, zip, host zip. On device: download, verify SHA-256, unzip, install atomically.

### Directory layout on disk

```
~/Library/Application Support/com.superpicky.mac/
├── ModelCache/
│   ├── v1/
│   │   ├── Models/
│   │   │   ├── yolo11l-seg.mlmodelc/
│   │   │   ├── osea_resnet34.mlmodelc/
│   │   │   ├── keypoint_resnet50.mlmodelc/
│   │   │   ├── flight_efficientnet.mlmodelc/
│   │   │   └── aesthetics.mlmodelc/
│   │   └── Data/
│   │       ├── bird_reference.sqlite
│   │       ├── avonet.db
│   │       ├── ebird_classid_mapping.json
│   │       └── offline_ebird_data/
│   │           ├── species_list_CN.json
│   │           ├── species_list_US-CA.json
│   │           └── ... (144 files)
│   └── .downloads/                          # partial downloads, deleted on success
```

Versioned directory (`v1/`) enables future manifest bumps to download cleanly alongside without a half-upgraded state.

### `ModelManager` actor

```swift
public actor ModelManager {
    public enum State: Sendable {
        case notStarted
        case downloading(progress: Double, currentFile: String)
        case verifying(file: String)
        case installing(file: String)
        case ready
        case failed(Error)
    }

    public private(set) var state: State = .notStarted

    public init(manifest: ModelManifest, rootDir: URL)

    /// Idempotent — call on every launch; fast if nothing to do.
    public func ensureReady() async throws

    /// Stream state updates for UI observation.
    public func observe() -> AsyncStream<State>

    /// Returns resolved URLs for every manifest entry. Must only be called after
    /// ensureReady() has returned successfully.
    public func resolvedPaths() throws -> ResolvedPaths
}
```

### Startup flow

```
AppDelegate / @main
    │
    ▼
ContentView.onAppear
    │
    ▼
ModelManager.ensureReady()   ─── async ───┐
    │                                      │
    │   emits state updates                │
    ▼                                      ▼
 state == .ready                       state == .downloading
    │                                      │
    │                                      │ First-Launch Sheet
    │                                      │ ── progress bar
    │                                      │ ── "Downloading species
 build CoreMLInferenceClient                │     classifier 108 MB..."
 swap into AppState.pipeline                │ ── cancel/retry
```

### Error handling

| Error | Behavior |
|---|---|
| Network unreachable | `.failed(NetworkUnavailable)`; sheet shows "Connect to the internet and retry" with a Retry button. **Offline first-launch is explicitly unsupported** (see Acceptance criterion #6). |
| Partial download interrupted | Resume via `URLSessionDownloadTask.cancel(byProducingResumeData:)`; `resumeData` persisted in `UserDefaults` keyed by entry id. On next launch, resume from where we left off. |
| Checksum mismatch | Delete partial, delete install dir. Retry with exponential backoff: 0s, 5s, 15s (3 attempts total). If still failing, `.failed(IntegrityFailure)`. |
| HTTP 5xx or timeout | Retry with exponential backoff: 2s, 8s, 30s (3 attempts). After that, `.failed(NetworkError)`. |
| HTTP 404 on a manifest URL | Hard fail immediately — this means the manifest itself is out of date. `.failed(ManifestOutdated)` with a message pointing the user at app update. No retry. |
| Disk full during unzip | Pre-check available space ≥ file size × 2. If insufficient, `.failed(DiskFull)` without deleting existing entries |
| `MLModel(contentsOf:)` rejects file | Wipe that entry's install dir, retry download once, else `.failed(ModelLoadFailure)` |

### Code-signing, Gatekeeper, and quarantine

Downloaded `.mlmodelc` directories are **compiled Core ML model bundles**, not Mach-O executables. Gatekeeper's translocation rules target `.app` bundles and command-line executables; `.mlmodelc` directories are treated as data files from a code-signing standpoint and load fine via `MLModel(contentsOf:)` without notarization concerns. Reference: Apple's Core ML sample projects (e.g., `Classifying Images with Vision and Core ML`) download `.mlmodel` files at runtime using the same pattern.

To be safe:
- `URLSession` downloads automatically set the `com.apple.quarantine` xattr on downloaded files. We **clear it** after checksum verification via `xattr -d com.apple.quarantine <path>` (or `removeExtendedAttribute:` equivalent API). Without this, `MLModel(contentsOf:)` may hit user-consent dialogs.
- We do **not** re-sign the downloaded `.mlmodelc` — the trust chain is "app is signed + manifest is signed + SHA-256 is in manifest." That's sufficient because Apple's runtime doesn't verify signatures on Core ML data files.
- First-launch test plan in Phase 6 includes: wipe Application Support, download models, launch, verify no Gatekeeper dialogs, verify `MLModel` loads clean.

### GRDB read-only configuration

Both `SpeciesDatabase` and `AvonetFilter` open their SQLite files with `Configuration.readonly = true`. This is important because:
- Downloaded files are installed to `~/Library/Application Support/.../ModelCache/v1/Data/` which is writeable by the app, but SQLite's default journaling mode (WAL) writes sidecar files on open even for read queries. Read-only mode skips journaling entirely.
- Files are the same bytes as the manifest's SHA-256 — any SQLite write would invalidate the checksum on next launch.
- Cleaner: no lock contention, no sidecar files, no corruption risk from a crash mid-query.

```swift
var config = Configuration()
config.readonly = true
let dbQueue = try DatabaseQueue(path: url.path, configuration: config)
```

### Dev & test bypass

- `SUPERPICKY_MODELS_DIR` environment variable — if set, `ModelManager` skips download and uses that directory directly. Used by developers, L2 parity tests, and CI.
- `ModelManager.preloadedReadyInstance(at:)` factory — returns a `ModelManager` already in `.ready` state for unit tests and previews.
- `MockModelManager` conforming to `ModelManagerProtocol` for test injection.

### Toggle interaction

The Settings "native vs HTTP backend" toggle inspects `ModelManager.state`. If not `.ready`, the native option is grayed out with tooltip "Downloading required models (X MB / Y MB)."

---

## Section 4 — Native port of preen's identify pipeline + loss audit

### The pipeline flow

```
identify(filePath, topK)
    │
    ▼
 1. RAWLoader.load(url)                     → CGImage (full-res)
 2. GPSExtractor.extract(url)               → (lat, lon)?
 3. YOLOBirdDetector.detectBirds(image)     → [BoundingBox] pixel coords
 4. avonet.buildFilterChain(lat, lon)       → [narrow, ..., nil] filter list
 5. For each bird box:
    a. SmartCrop.crop(image, box)           → cropped CGImage
    b. OSEAClassifier.logits(crop, .directResize) → [Float] raw logits
    c. SpeciesFilterChain.bestMatch(logits, filters, ...) → SpeciesMatch?
 6. Return IdentifyResponse(species, birds, totalDetected)
```

### Types

**`SmartCrop`** — pure function. Direct port of `preen/detector.py:_smart_crop` (lines 69–95). Square crop centered on bbox with 1.15× padding; if the expanded box hits the image edge, letterbox to square with black fill.

**`YOLOBirdDetector`** — thin wrapper around a Core ML YOLO model. Input: letterboxed 640×640 `CVPixelBuffer`. Output: boxes, confidences, class IDs → filter class == 14 → NMS at IoU 0.45 → un-letterbox coordinates → return `[BoundingBox]` in original-image pixel space. Also returns segmentation masks for the `/detect` endpoint.

**`OSEAClassifier`** — wraps the 10964-class ResNet34 Core ML model. Input: 224×224 RGB `MLMultiArray` with ImageNet normalization, Lanczos-resized from bird crop. Runs prediction on original + h-flipped inputs, averages raw logits, trims to 10964. Returns `[Float]` logits (not softmaxed, not thresholded).

**`SpeciesFilterChain`** — pure algorithm. Direct port of `_get_species_filter_chain` + `predict_from_logits`. For each filter in the chain: apply species mask (non-allowed classes → −∞), softmax(masked / 0.9), top-1, check threshold (regional 80 or global 90), return first match.

**`AvonetFilter`** — GRDB-backed GPS filter. Port of `preen/birdid/avonet_filter.py`. Three query methods: `speciesByGPS(lat, lon)`, `speciesByCountryEbird(lat, lon)`, `speciesByRegionEbird(regionCode)`. Internally depends on `RegionBounds` for country-from-GPS lookup.

### Loss audit — what the native port must preserve

The following is the complete list of behaviors that must not drift during the port. Each row becomes a test assertion or code-review checkbox in the implementation plan.

#### A. Model hyperparameters (hardcoded magic numbers)

| Model | Parameter | Value | Source |
|---|---|---|---|
| YOLO | Bird class ID | **14** (COCO) | `preen/detector.py:11` |
| YOLO | Input size | 640×640 letterboxed | ultralytics default |
| YOLO | NMS IoU threshold | 0.45 | ultralytics default |
| YOLO | Conf threshold | 0.25 | ultralytics default |
| OSEA | Input size | **224×224** | `osea_classifier.py:98` |
| OSEA | Interpolation for YOLO crops | **Lanczos** | `osea_classifier.py:98` |
| OSEA | Preprocessing for non-YOLO crops | Resize(256) → CenterCrop(224) | `osea_classifier.py:86` |
| OSEA | ImageNet mean | `[0.485, 0.456, 0.406]` | `osea_classifier.py:91` |
| OSEA | ImageNet std | `[0.229, 0.224, 0.225]` | `osea_classifier.py:91` |
| OSEA | Total classes in checkpoint | **11000** (model output shape) | `osea_classifier.py:154` |
| OSEA | Classes actually used | **10964** (`len(bird_info)`) | `osea_classifier.py:177` |
| OSEA | Temperature | **0.9** | `osea_classifier.py:104` |
| OSEA | TTA | average **logits** (not probs) of original + horizontal flip | `osea_classifier.py:130–144` |
| OSEA | Trim step | `output[:len(bird_info)]` — discard classes 10964..10999 | `osea_classifier.py:199` |
| OSEA | Min confidence after softmax | 0.3 × 100 = **0.3%** (dead filter in practice) | `osea_classifier.py:231` |
| SpeciesFilter | Regional threshold | **80.0** | `python-server/inference/species.py:7` |
| SpeciesFilter | Global threshold | **90.0** | `python-server/inference/species.py:8` |
| SmartCrop | Padding factor | **1.15** | `preen/detector.py:76` |
| SmartCrop | Letterbox fill color | **(0, 0, 0)** | `preen/detector.py:92` |
| Keypoint | Architecture | **ResNet50 backbone + 2-layer MLP + separate coord_head + vis_head** (NOT stock ResNet50) | `keypoint_detector.py:38–64` |
| Keypoint | Input size | **416×416** (not 224) | `keypoint_detector.py:71` |
| Keypoint | Visibility threshold | **0.3** | `keypoint_detector.py:72` |
| Keypoint | Output | `coords` (3,2) sigmoid + `vis` (3) sigmoid — **two tensors** | `keypoint_detector.py:60–64` |
| Keypoint | Coord space | 0–1 normalized via sigmoid; Swift multiplies by crop w/h to get pixels | `keypoint_detector.py:166–168` |
| Keypoint | FP16 on MPS | Yes — Python uses half precision (potential parity drift) | `keypoint_detector.py:125` |
| Flight | Architecture | **EfficientNet-B3** with custom head: `Dropout(0.2) + Linear + Sigmoid` | `flight_detector.py:82–93` |
| Flight | Input size | **384×384** (NOT 224) | `flight_detector.py:38` |
| Flight | Threshold | **0.5** | `flight_detector.py:39` |
| Flight | Output | Scalar probability 0–1 (sigmoid applied inside the model) | `flight_detector.py:92` |
| Flight | Normalization | ImageNet mean/std | `flight_detector.py:69–72` |
| Aesthetics | Model | **TOPIQ** via `topiq_model.TOPIQScorer` | `aesthetics.py:13` |
| Aesthetics | Range | Unknown without spike — see Phase 5 | `aesthetics.py:22` |

#### B. Data files that must ship

| File | Size (approx) | Purpose |
|---|---|---|
| `bird_reference.sqlite` | ~2 MB | 10964-class lookup with `chinese_simplified`, `english_name`, `scientific_name`, `chinese_traditional`, **`pinyin_initials` (new column, pre-computed at packaging time)** |
| `avonet.db` | ~107 MB | `distributions` + `places` + `sp_cls_map` tables for GPS-based species filtering |
| `ebird_classid_mapping.json` | ~50 KB | eBird code (string) → OSEA class ID (int) mapping |
| `offline_ebird_data/species_list_*.json` | 144 files, ~5 MB total | Per-country/region species code lists |
| `offline_ebird_data/offline_index.json` | small | Index of available region files |

#### C. Algorithms that aren't ML inference but affect output

| # | Algorithm | Source | Ported to |
|---|---|---|---|
| 1 | Smart crop (square + 1.15× pad + letterbox) | `preen/detector.py:69–95` | `SmartCrop.swift` |
| 2 | TTA logit averaging | `osea_classifier.py:130–144` | `OSEAClassifier.swift` |
| 3 | Class mask + tempered softmax + top-k | `osea_classifier.py:201–244` | `SpeciesFilterChain.swift` |
| 4 | Filter chain fallback (GPS → country eBird, skip-if-equal → global) | `preen/detector.py:195–225` | `SpeciesFilterChain.swift` |
| 5 | Country-from-GPS tiebreak (smallest area wins) | `avonet_filter.py:261–274` | `RegionBounds.swift` |
| 6 | GPS bbox-overlap SQL query | `avonet_filter.py:226–241` | `AvonetFilter.swift` |
| 7 | GPS point-in-bbox SQL query | `avonet_filter.py:206–217` | `AvonetFilter.swift` |
| 8 | Region file fallback (`US-CA` → `US`) | `avonet_filter.py:307–319` | `AvonetFilter.swift` |
| 9 | eBird code → class ID mapping | `avonet_filter.py:276–294` | `AvonetFilter.swift` |
| 10 | EXIF GPS extraction (DMS → decimal, N/S/E/W sign) | `preen/folder.py:78–116` | `GPSExtractor.swift` (via CGImageSource, not piexif) |
| 11 | Pinyin generation | `species.py:11–14` | **Pre-compute at packaging time**; store in `bird_reference.sqlite` as new column |
| 12 | RAW decode | `preen/folder.py:65–75` (rawpy) | Existing Swift `RAWConverter` via `CGImageSource` |
| 13 | Bird-info class lookup fallback | `osea_classifier.py:178` | `SpeciesDatabase.swift` |
| 14 | Graceful AVONET degradation | `preen/detector.py:221–224` | `AvonetFilter.swift` |

#### D. Edge cases (each gets an explicit L1 unit test)

| # | Scenario | Expected behavior |
|---|---|---|
| 1 | Photo with no GPS EXIF | Filter chain = `[global]` only; uses global threshold (90) |
| 2 | GPS present but AVONET returns empty set | Skip level 1, try level 2 |
| 3 | GPS present, level 1 == level 2 | Skip level 2 (matches `preen/detector.py:211`) |
| 4 | Photo at country-bounds edge (lat/lon exactly on boundary) | Equality is inclusive (SQL `BETWEEN`) |
| 5 | Bird box at image edge | Clamp + letterbox to black |
| 6 | No birds detected | Return `IdentifyResponse(species: [], birds: [], totalDetected: 0)` — do NOT error |
| 7 | Birds detected but all below 80% regional and 90% global | Return boxes but empty species list |
| 8 | OSEA class ID not in `bird_reference.sqlite` | Return "Unknown" placeholder |
| 9 | `avonet.db` missing entirely | Filter chain = `[global]`; warn once; don't crash |
| 10 | `species_list_XX.json` missing for detected country | Level 2 returns empty, fall through to global |
| 11 | Bird crop is 0×0 after smart crop | Skip this bird, don't crash |
| 12 | Photo file unreadable | Throw `InferenceError.imageConversionFailed` |
| 13 | Photo is RAW but `RAWConverter` fails | Throw, don't return garbage |
| 14 | Top-1 confidence == exact threshold (80.0 or 90.0) | Use `>=` (matches preen line 171) |
| 15 | Duplicate species across multiple birds in one photo | Return all (no dedup at this layer) |
| 16 | Keypoint input crop smaller than 416×416 | Resize up (matches Python `transforms.Resize((416,416))`) |
| 17 | Flight input crop not square | Resize to 384×384 (stretches; matches Python) |
| 18 | Empty/nil crop for keypoints | Return all-zero keypoints result |

#### E. Known parity-drift sources (can't achieve bit-exact)

1. **RAW decode** — preen uses rawpy; Swift uses `CGImageSource`. Different demosaic, different default white balance, different tone curve. Tolerance: downstream YOLO boxes IoU ≥ 0.95; species top-1 match ≥ 98% on curated fixtures. (Note: today's pipeline already has mixed RAW decode paths — native is strictly more consistent.)
2. **FP16 vs FP32** — Python keypoint detector runs FP16 on MPS. Core ML auto-selects precision per compute unit. Tolerance: each keypoint within ±5 pixels at 416 input resolution.
3. **vImage Lanczos vs PIL Lanczos** — both are Lanczos but window sizes may differ. Tolerance: OSEA top-5 overlap ≥ 4/5.
4. **TOPIQ swap (if needed)** — absolute score range shifts. Tolerance: Spearman rank correlation ρ ≥ 0.85 on ranked fixtures.

#### F. Explicit drops (no loss)

- `sys._MEIPASS` PyInstaller path handling — not shipping Python
- `from config import get_best_device` — Core ML handles compute-unit selection
- `rawpy`, `piexif`, `pillow_heif`, `pillow_jxl`, `pillow_avif` — replaced by native Swift/ImageIO
- `detect_batch` method — SuperPicky is photo-at-a-time
- `reverse_geocode` (CLGeocoder) in preen — used for IPTC, not for species ID
- `write_iptc` (exiftool subprocess) — SuperPicky writes XMP in Swift
- `/detect` bytes-upload flow — unused by Swift pipeline today
- `/identify` image-bytes fallback — only used by Python tests
- `ProcessManager` Python subprocess launcher — no process to launch
- `MockInferenceClientForUI` — unchanged; backend-agnostic, continues to work post-Phase-7 (see Section 2 "MockInferenceClientForUI adaptation")

#### F2. Intentionally pre-existing divergence (NOT a regression; documented to prevent future panic)

The Python keypoint detector (`keypoint_detector.py:_calculate_head_sharpness`, lines 219–355) computes a **head sharpness** score using:
- `RADIUS_MULTIPLIER = 1.2` (eye-to-beak distance × 1.2 = disc radius)
- `NO_BEAK_RADIUS_RATIO = 0.15` (fallback when beak not visible)
- `LOW_VIS_PENALTY = 0.8` (scales result down when both eyes below visibility threshold)
- Tenengrad (Sobel-gradient-squared) over a circular mask AND'd with the YOLO segmentation mask
- Log-normalization with `MIN_VAL=100, MAX_VAL=154016` → output 0–1000

**This entire sub-algorithm is already not used by SuperPicky.** The Python HTTP `/keypoints` endpoint computes `head_sharpness` but does NOT return it — `python-server/inference/keypoints.py` extracts only `left_eye`, `right_eye`, `beak` positions and visibilities into the JSON response. SuperPicky's Swift side computes its own sharpness metric via `EyeCropSharpness.score(...)` (Laplacian variance in a patch around each visible eye) — a completely different algorithm.

**Native port behavior:** Drop the Python head-sharpness computation entirely. The Swift `EyeCropSharpness` is the production algorithm, has been for months, and is **not** changing in this rewrite. A future reviewer running a diff between legacy Python output and native Core ML output on the keypoint endpoint will see identical JSON schemas — no head_sharpness in either — and should not be alarmed.

**Why this is called out explicitly:** the loss-audit reviewer flagged this as a risk even though it's correct. Adding this row to the spec prevents a future reader from treating dead Python code as "something we lost."

#### F3. `_to_pinyin` `errors="ignore"` consistency

Three places in the Python stack call pypinyin:
- `preen/detector.py:228-231` — `_to_pinyin` without `errors="ignore"`
- `python-server/inference/species.py:11-14` — `_to_pinyin` WITH `errors="ignore"`
- Our new `tools/build-species-db.py` — WITH `errors="ignore"`

**The existing Swift side sees the python-server output** (via the HTTP `/identify` endpoint), so the python-server behavior is the ground truth. We match python-server: use `errors="ignore"`. This is documented in the build script and reproduced by a build-time test asserting the generated column matches python-server output for a fixture of ~50 species names (including edge-case Chinese characters that would trigger the `errors` behavior difference).

---

## Section 5 — Species data storage

### Three Swift types

**`SpeciesDatabase`** — GRDB read-only `DatabaseQueue`, preloads all 10964 rows at init into `[SpeciesInfo]` indexed by class ID. Lookup is an array access, not a SQL query. ~2 MB RAM cost; eliminates per-call SQL round-trip on the hot path.

```swift
public final class SpeciesDatabase: Sendable {
    private let dbQueue: DatabaseQueue  // opened with Configuration.readonly = true
    public init(url: URL) throws { ... }
    public func lookup(classID: Int) throws -> SpeciesInfo
    public func preloadAll() throws -> [SpeciesInfo]
}

public struct SpeciesInfo: Sendable {
    public let cnName: String           // defaults to "Unknown"
    public let enName: String           // defaults to "Unknown"
    public let scientificName: String
    public let cnTrad: String
    public let pinyinInitials: String   // pre-computed at packaging time; first-letter abbreviation
                                        // e.g. "白鹭" → "bl" (not "baili" or "baílù")
}
```

**Naming note:** the column and property are named `pinyinInitials` (not `pinyin`) because `preen._to_pinyin` joins the **first letter of each pinyin syllable**, not the full pinyin. A future contributor adding full-pinyin support would add a separate `pinyinFull` column; `pinyinInitials` makes the current semantics unambiguous.

**`AvonetFilter`** — GRDB-backed GPS/country queries. Lazy SQL execution (cold path, called once per photo). Loads `ebird_classid_mapping.json` once at init. Caches region JSON files after first read.

**`RegionBounds`** — compile-time Swift constant generated from `avonet_filter.py:18–164`. 160+ country/region entries. Direct port of `_detect_country_from_gps` tiebreak (smallest-bounding-box wins).

### Load strategy

| Type | Lifetime | Strategy | Rationale |
|---|---|---|---|
| `SpeciesDatabase` | Preload at client init | `[SpeciesInfo]` array in RAM | Hot path — called 5× per bird per photo |
| `AvonetFilter` | Lazy | GRDB read-only + OS page cache | Cold path — called once per photo |
| `RegionBounds` | Compile-time | Swift constant | Immutable, source-of-truth is preen's Python file |

### Pinyin pre-compute step

The new column is named `pinyin_initials` in SQL (snake_case, matching the existing schema's `chinese_simplified`, `chinese_traditional`, etc.). The Swift side reads it into the `pinyinInitials` property via GRDB's automatic snake-case → camelCase conversion (or an explicit `CodingKeys` if the class doesn't enable automatic conversion).

```python
# tools/build-species-db.py (run once per model release)
import sqlite3
from pypinyin import Style, pinyin

conn = sqlite3.connect("bird_reference.sqlite")
conn.execute("ALTER TABLE BirdCountInfo ADD COLUMN pinyin_initials TEXT DEFAULT ''")

for row in conn.execute("SELECT model_class_id, chinese_simplified FROM BirdCountInfo"):
    cls, cn = row
    if cn:
        py = "".join(p[0] for p in pinyin(cn, style=Style.NORMAL, errors="ignore"))
        conn.execute("UPDATE BirdCountInfo SET pinyin_initials = ? WHERE model_class_id = ?",
                     (py, cls))
conn.commit()
```

- `pypinyin` version pinned in `tools/requirements.txt`; regeneration checked by CI
- Build-time assertion: `pinyin_initials` non-empty for every row with non-empty `chinese_simplified`
- Storage cost: ~50 KB added to `bird_reference.sqlite`
- `SpeciesDatabase.lookup()` reads the column via `row["pinyin_initials"]` and maps to `SpeciesInfo.pinyinInitials`

### Download format

| Artifact | Download | Installed |
|---|---|---|
| `bird_reference.sqlite` | `.gz` (~500 KB) | Uncompressed (~2 MB) |
| `avonet.db` | `.gz` (~40 MB) | Uncompressed (~107 MB) |
| `ebird_classid_mapping.json` | `.gz` (~10 KB) | Uncompressed (~50 KB) |
| `offline_ebird_data/*.json` (144 files) | Single `.tar.gz` (~400 KB) | Extracted directory (~5 MB) |

(The manifest entry at the top of Section 3 uses 40000000 bytes for `avonet.db.gz`, consistent with this row.)

### Swift constants file — thresholds are not inline literals

All Python-sourced magic numbers live in a single `InferenceConstants.swift` in `SuperPickyInference/` so that drift from the Python source is visible in one diff:

```swift
// SuperPickyInference/InferenceConstants.swift
public enum InferenceConstants {
    // OSEA / species classifier — source: python-server/inference/species.py
    public static let regionalSpeciesThreshold: Float = 80.0
    public static let globalSpeciesThreshold: Float = 90.0
    public static let oseaTemperature: Float = 0.9
    public static let oseaNumClasses = 10964        // model outputs 11000; we trim
    public static let oseaInputSize = 224
    public static let oseaMinConfidencePercent: Float = 0.3  // preen's dead filter, preserved

    // YOLO — source: ultralytics defaults + preen/detector.py:11
    public static let yoloBirdClassID = 14           // COCO
    public static let yoloInputSize = 640
    public static let yoloNMSThreshold: Float = 0.45
    public static let yoloConfThreshold: Float = 0.25

    // Keypoint — source: ~/projects/SuperPicky/core/keypoint_detector.py
    public static let keypointInputSize = 416
    public static let keypointVisibilityThreshold: Float = 0.3

    // Flight — source: ~/projects/SuperPicky/core/flight_detector.py
    public static let flightInputSize = 384
    public static let flightThreshold: Float = 0.5

    // Smart crop — source: preen/detector.py:69-95
    public static let smartCropPaddingFactor: Float = 1.15

    // ImageNet normalization — source: every torchvision model ever
    public static let imageNetMean: SIMD3<Float> = [0.485, 0.456, 0.406]
    public static let imageNetStd: SIMD3<Float> = [0.229, 0.224, 0.225]
}
```

`CoreMLInferenceClient.identify()`, `SpeciesFilterChain.bestMatch()`, and each model wrapper reference these constants rather than hardcoding literals. Every threshold has a source citation in the comment so a future port back to Python (or drift comparison) is a single-file task.

### Cold init budget

```
CoreMLInferenceClient.init(modelManager:)
├── YOLOBirdDetector.init               ~50 ms
├── OSEAClassifier.init                 ~120 ms
├── KeypointModel.init                  ~60 ms
├── FlightModel.init                    ~30 ms
├── AestheticsModel.init                ~40 ms
├── SpeciesDatabase.init + preloadAll   ~10 ms
└── AvonetFilter.init                   ~20 ms
                                        ─────
                                        ~330 ms (expect <400 ms)
```

Plus Bundle load + AppDelegate + MainView first paint (~350 ms on M1) + GRDB open for the report.db (~20 ms) + first render (~50 ms) = **~750 ms total** to "ready to process folder" on a baseline M1 MacBook Air with warm model cache. Cold disk can push this to ~1 sec; that's the acceptance-criterion target (not contract).

One-time cost; never per-photo.

### Memory budget

Peak resident memory during a full-pipeline run on a single photo:

| Source | Size |
|---|---|
| 5 × `MLModel` instances loaded (compiled weights + activation buffers) | ~350 MB |
| `SpeciesDatabase` preloaded 10964-row array | ~2 MB |
| `AvonetFilter` GRDB connection + region JSON cache | ~5 MB |
| Full-resolution decoded RAW `CGImage` (typical Sony ARW at 24MP sRGB8) | ~75 MB |
| Bird crop `CGImage` (varies; typically ~5 MB) | ~5 MB |
| Concurrent inference activations — YOLO 640×640, OSEA 224×224×2 (TTA), keypoint 416×416, flight 384×384, aesthetics | ~150 MB peak during parallel fan-out |
| App baseline (SwiftUI, NSApplication, GRDB report.db) | ~120 MB |
| **Peak RSS during a parallel fan-out** | **~707 MB** |

**8 GB Mac implications:** baseline peak ~700 MB is well within a 4 GB working set budget. The concern is when `PipelineCoordinator` batches through many photos and the OS doesn't free the previous photo's `CGImage` fast enough — if autoreleasepool pressure builds, RSS can climb to 1.5–2 GB on an intensive run. Mitigation: wrap the per-photo loop in `autoreleasepool { ... }` to force immediate release after each photo's inference completes. **This is already a Phase 0 commit** — added to the foundation phase because it's a cheap prophylactic that prevents a class of failure mode.

**16 GB+ Mac:** not a concern. The rewrite may actually use less memory than today's Python pipeline because today we pay both the Swift-side `CGImage` and the Python-side PIL/torch tensors for every photo.

**Continuous processing of 1000+ photo folders:** measured in Phase 4 parity tests as part of Gate #2. If RSS grows unbounded, that's a memory-leak bug and gets fixed before Phase 6. Explicit acceptance check: after processing 500 photos, `ps -o rss=` for the app process should be ≤ 1.5 GB.

### Localization

All new UI strings (Settings toggle, first-launch download sheet, progress indicator, retry button, error messages) use `config.localized("key")` with entries in both `en.lproj/Localizable.strings` and `zh-Hans.lproj/Localizable.strings`. Per CLAUDE.md retrospective: "Every Text/Label/Section must use config.localized(); add to both .strings files." Every PR that adds user-visible strings MUST add both translations in the same commit. Reviewer checks this against `grep -n "Text(\"" new files` before approving.

Strings to add at Phase 6:
- "Downloading required models" / "正在下载所需模型"
- "{bytes_done} of {bytes_total}" / "已下载 {bytes_done} / {bytes_total}"
- "Connect to the internet and retry" / "请连接网络后重试"
- "Downloading species classifier (108 MB)..." / "正在下载物种识别模型 (108 MB)..."
- etc.

---

## Section 6 — Parity testing

### Target layout

```
apps/mac-client/SuperPickyTests/Parity/
├── ParityTestBase.swift          # Shared setup: boot both clients, load fixtures
├── EndpointParityTests.swift     # Gate #1 — per-endpoint tolerance
├── RatingParityTests.swift       # Gate #2 — end-to-end rating diff
├── Fixtures/                     # ~30 real photos (git-lfs)
│   ├── singles/                  # Single bird, sharp, good exposure
│   ├── flocks/                   # Multiple birds
│   ├── flight/                   # In-flight
│   ├── keypoint-edge/            # Head turned, eye hidden
│   ├── exposure/                 # Over/under
│   ├── no-bird/                  # Landscape, human, empty sky
│   ├── no-gps/                   # EXIF GPS stripped
│   └── rare-species/             # Top-1 near threshold
└── ExpectedOutputs/              # Golden-file snapshots (generated once, checked in)
```

### Fixture allocation

| Bucket | Count | Must exercise |
|---|---|---|
| singles | 20 | Sharp bird, 1 species, GPS — the baseline for species top-1 parity |
| flocks | 10 | Multiple birds → OSEA called multiple times per photo |
| flight | 8 | Flight True and False paths |
| keypoint-edge | 8 | Head turned, eye hidden, beak-only, both eyes hidden |
| exposure | 6 | Over, under, borderline |
| no-bird | 6 | YOLO should return 0 |
| no-gps | 6 | Filter chain fallback to country/global |
| rare-species | 6 | Top-1 near 80 regional threshold (tests filter chain) |
| species-diversity | 20 | Species from different families (corvids, raptors, waterfowl, passerines, shorebirds) to spread OSEA class IDs across the embedding space |
| **Total** | **90** | |

**Why 90 not 30:** reviewer pointed out that 30 photos for a 10964-class classifier is too few for strict Gate #1 top-1 species matching — a single FP16-vs-FP32 disagreement at the top of softmax would fail the gate from a single photo. 90 photos gives ~40 photos that actually produce species identifications (the others are no-bird, exposure edge cases, etc.), which is statistically meaningful at the Gate #1 tolerances below.

Each fixture has a `manifest.json` sibling listing expected species, bird count, flight label, exposure label. Total LFS payload: ~600 MB including RAW samples.

### Gate #1 — `EndpointParityTests.swift`

Per-endpoint tolerances. Runs on every PR. Blocks merge if any assertion fails.

| Endpoint | Tolerance |
|---|---|
| `detect` | Bird count equal; per-box IoU ≥ 0.95; confidence ±0.02 |
| `aesthetics` | Score ±0.3 if TOPIQ converts; Spearman ρ ≥ 0.85 if swapped |
| `keypoints` | Each keypoint ±5 px at 416×416; visibility ±0.1 |
| `flight` | `isFlying` exact match; confidence ±0.05 |
| `identify` (aggregate across fixture set) | Top-1 scientific-name match rate **≥ 90%** across the `singles + flocks + species-diversity + rare-species` buckets (≥ 56/62 photos); top-5 overlap ≥ 4/5 in ≥ 80% of those same photos; top-1 confidence ±2 pp when the top-1 matches; `totalDetected` equal on every photo. Gate is aggregate-over-fixtures, not per-fixture strict, because of documented FP16/Lanczos drift in Section 4E. |

**Tolerance rationale:**
- IoU 0.95 — standard "same object" threshold in detection benchmarks
- Confidence ±0.02 — accommodates float32 → float16 drift in Core ML
- Keypoint ±5 px — ~1.2% relative error, accommodates FP16 MPS vs Core ML precision
- Species top-1 strict — top-5 overlap ≥ 3/5 acknowledges minor probability shuffling

**Harness:** `scripts/run-parity-l2.sh` boots L2 Python server on 18420, stages model cache, runs XCTest target. Added to `scripts/pre-push.sh`; runs on CI (self-hosted runner per `azure-vm` skill).

**Progressive enablement:** during Phase 1 (Flight), only `test_flight_parity` is enabled; others marked with `throw XCTSkip("endpoint not yet native")`. Each phase enables its endpoint's tests.

### Gate #2 — `RatingParityTests.swift`

Runs once per phase, not per PR. Runs a real folder through both pipelines end-to-end and diffs the `.report.db`.

**Assertions (exact definitions — the reviewer asked for these to be unambiguous):**

- **Photo count:** `httpPhotos.count == nativePhotos.count` (trivial — but asserts scan path didn't drift)
- **Strict rating match rate:** `count_of(h.starRating == n.starRating) / total ≥ 90%`
- **Relaxed rating match rate:** `count_of(abs(h.starRating - n.starRating) ≤ 1) / total ≥ 98%`. This is the primary gate — it tolerates one-bit shifts in sub-scores pushing a photo across a star boundary without calling that a regression.
- **Mean absolute rating difference:** `mean(abs(h.starRating - n.starRating)) ≤ 0.1` (0 = perfect, 5 = worst)
- **Species top-1 match rate** (only over photos where *both* runs identified a species): `count_of(h.speciesScientificName == n.speciesScientificName) / compared ≥ 95%`
- **Species identification rate agreement:** `abs(http_id_rate - native_id_rate) ≤ 2%` — catches the case where one backend identifies many more photos than the other (filter chain bug)
- **Pick rate agreement:** `abs(http_pick_count - native_pick_count) / total ≤ 2%` — catches regressions in the rating-5 boundary specifically
- Mismatch list printed on failure for debugging (filename, http rating, native rating)

**Why relaxed rating is the primary gate:** star ratings are computed from 6+ sub-scores (sharpness, aesthetics, exposure, species confidence, flight, keypoint visibility) and each has its own tolerance budget. A photo whose aesthetics shifts ±0.3 (within Gate #1 tolerance) can cross a moderate-vs-good threshold in `RatingEngine.calculate()` and jump from 3 stars to 4. Strict match on ≥ 90% AND relaxed match (±1 star) on ≥ 98% captures "most photos behave identically, a few drift by one star at threshold boundaries" without forcing a false failure.

**Why strict 90% not 95%:** tested empirically in Phase 4 — we'll tune this number after running the first real folder. The 90% is a floor, not a target. The goal is ≥ 95% strict in practice; 90% is the gate to allow some drift from TOPIQ's Path B swap.

**Requires:** `PipelineCoordinator.process` gains an optional `databaseName` parameter defaulting to `.report.db` for back-compat; parity test passes `.report-http.db` / `.report-native.db` for side-by-side runs. Minimal surface-area change.

**When Gate #2 runs:**
- End of Phase 4 (OSEA pipeline native) — target ≥98% (aesthetics still HTTP in both runs to isolate drift)
- End of Phase 5 (aesthetics native) — final target ≥95%
- Start of Phase 6 (toggle default flip) — real user folder smoke test
- Phase 7 (kill Python) — final run before deletion

### Golden-file strategy

After Gate #1 passes, native output snapshots to `ExpectedOutputs/<filename>.expected.json`. Post-Phase 7 (Python deleted), `EndpointParityTests` switches from HTTP-comparison mode to snapshot-comparison mode. No tests deleted when HTTP client goes away. Catches regressions in future Core ML runtime updates, model re-exports, or compute-unit tuning changes.

### Fixture storage

Git LFS:

```
apps/mac-client/SuperPickyTests/Parity/Fixtures/**/*.jpg filter=lfs diff=lfs merge=lfs
apps/mac-client/SuperPickyTests/Parity/Fixtures/**/*.arw filter=lfs diff=lfs merge=lfs
apps/mac-client/SuperPickyTests/Parity/Fixtures/**/*.heic filter=lfs diff=lfs merge=lfs
```

Total LFS payload ~200 MB for 30 photos including RAWs.

### Bonus — performance timings

Parity test records wall-clock time per endpoint and per whole pipeline to `parity-timings.json`. Not a gate, but reported at kill-Python time. Expectation: native 2–4× faster on full pipelines.

---

## Section 7 — Rollout sequence

Seven phases, seven PRs. Each phase bounded, individually mergeable, reversible via feature toggle until Phase 7.

### Phase 0 — Foundation (1 PR, ~6 commits)

Scaffolding only. No new model, no new endpoint.

| # | Commit | What |
|---|---|---|
| 1 | `feat(spm): add SuperPickyInference SPM target` | Add target to `Package.swift`, empty folder, add to `.xcodeproj` |
| 2 | `feat(manifest): add ModelManifest type + bundled stub manifest.json` | Schema, zero-entry stub |
| 3 | `feat(manager): add ModelManager actor with ensureReady() (no-op for empty manifest)` | Actor + state machine + observe stream |
| 4 | `feat(pipeline): wrap per-photo loop in autoreleasepool` | Prophylactic memory fix before ML objects get added. Wraps the body of [`PipelineCoordinator.process`'s `for fileURL in files`](apps/mac-client/SuperPickyApp/PipelineCoordinator.swift:55) inner loop in `autoreleasepool { ... }`. Costs nothing today (existing types are already ARC-clean) but guarantees that when Phase 2 adds `MLMultiArray` allocations inside that loop, they get released at each iteration boundary. Prevents a class of memory-growth bugs before it can happen. Reference: memory budget in Section 5. |
| 5 | `feat(ui): add InferenceBackendSetting in Settings (HTTP only, native grayed out)` | Toggle UI, native disabled with tooltip. All strings localized in both en and zh-Hans `.strings` files. |
| 6 | `chore(tests): add Parity test target, empty ParityTestBase, skip-all-tests` | XCTest target compiles, zero active tests. Also adds the optional `databaseName: String = ".report.db"` parameter to `PipelineCoordinator.process` so Parity tests can run side-by-side databases in Phase 4b. |

**Gate:** `swift build`, `swift test`, existing L1/L2/L3 all pass.

### Phase 1 — Flight (EfficientNet) (1 PR, ~8 commits)

First real native model. Smallest, simplest. **Hardens the shipping pipeline with the lowest-stakes model.**

| # | Commit | What |
|---|---|---|
| 1 | `tools: add scripts/convert-flight-to-coreml.py` | Load `.pth`, rebuild EfficientNet-B3 head exactly (Dropout(0.2) + Linear + Sigmoid), trace, convert. Output: `.mlmodelc.zip` + SHA-256 |
| 2 | `tools: add scripts/package-models.sh` | Orchestrates conversion, zip, checksum, manifest writing |
| 3 | `feat(inference): add FlightModel Swift wrapper` | 384×384 CVPixelBuffer, ImageNet norm, `FlightResult(isFlying: prob > 0.5, confidence: prob)` |
| 4 | `test(inference): FlightModel preprocessing + sigmoid output + fresh-buffer rule` | Fixed-input test, ±0.01 vs Python. Also: **concurrency test** asserts that two parallel `predict()` calls on the same `FlightModel` instance produce identical outputs (each allocates its own `MLMultiArray`; no shared mutable buffer). This test is copy-pasted into every subsequent model wrapper's test file (Phase 2 keypoint, Phase 3 YOLO, Phase 4b OSEA, Phase 5 aesthetics) so the fresh-buffer rule is enforced on every model, not just the first one. |
| 5 | `feat(inference): add CoreMLInferenceClient with flight() only; other methods throw notYetImplemented` | Stub; only flight() real |
| 6 | `feat(manager): add flight manifest entry; ensureReady downloads it` | First real manifest entry |
| 7 | `feat(ui): enable native toggle; PipelineCoordinator falls back to HTTP for unimplemented methods` | Hybrid routing — toggle works, per-endpoint fallback |
| 8 | `test(parity): enable test_flight_parity against fixture set` | Gate #1 flight test no longer skipped |

**Gate:** `test_flight_parity` green; 10-photo test folder processes without errors; flight timing reported.

### Phase 2 — Keypoint (ResNet50 custom head) (1 PR, ~8 commits)

| # | Commit | What |
|---|---|---|
| 0 | `spike: verify PartLocalizer checkpoint loads into rebuilt architecture` | Load `cub200_keypoint_resnet50_slim.pth` into a freshly built `PartLocalizer` (ResNet50 backbone + `Linear(2048, 512) + BatchNorm1d(512) + ReLU + Dropout(0.2) + Linear(512, 256) + BatchNorm1d(256) + ReLU + Dropout(0.2)` head + `coord_head Linear(256, 6)` + `vis_head Linear(256, 3)`). Verify state-dict keys match exactly (was Open Question #1). Report in PR description. If keys mismatch, this commit is rejected and Phase 2 restarts with a key-mapping step. |
| 1 | `tools: add scripts/convert-keypoint-to-coreml.py` | Rebuild `PartLocalizer` exactly; **set `model.eval()` before tracing** so `BatchNorm1d` folds to running_mean/running_var constants (mandatory — BN1d in train mode produces non-determenistic output and the trace won't convert cleanly). Use `torch.jit.trace` on a fixed dummy input; verify the traced graph has two output nodes corresponding to the `coords` and `vis` tensors. If trace fails because of the multi-output forward, fall back to `torch.jit.script` on the `PartLocalizer.forward` method — script handles Python control flow that trace can't. Emit a multi-output `.mlpackage`. |
| 2 | `feat(inference): add KeypointModel Swift wrapper` | Input 416×416 (NOT 224), parse `coords` (3×2) and `vis` (3) from the multi-output `MLModel`. Assert at init time that the loaded model emits exactly these two output features with these shapes — catches a converted model whose output names/shapes drifted. |
| 3 | `test(inference): KeypointModel preprocessing + output parsing` | Incl. empty-crop edge case. Also: assert the converted model's output shape on a fixed input matches Python's output shape (dual-output sanity check). |
| 4 | `feat(inference): wire keypoints() into CoreMLInferenceClient` | Remove `notYetImplemented` |
| 5 | `feat(manager): add keypoint manifest entry` | |
| 6 | `test(parity): enable test_keypoints_parity` | Singles + keypoint-edge fixtures |
| 7 | `perf(inference): micro-benchmark compute units for keypoint model` | Pin best `MLModelConfiguration.computeUnits` into `ModelConfiguration.keypoint` |

**Gate:** Flight + keypoints parity green.

### Phase 3 — YOLO segmentation (`/detect`) (1 PR, ~10 commits)

| # | Commit | What |
|---|---|---|
| 0 | `spike: export yolo11l-seg to Core ML and document outputs` | Run `ultralytics.YOLO("yolo11l-seg.pt").export(format='coreml')` on the ops workstation. **Gate rest of Phase 3 on outcome.** Document in the PR description: does it produce a `.mlmodel`, `.mlpackage`, or both? What are the output names/shapes? Does it bake in NMS or leave it for us? Does it emit mask prototypes as a separate tensor or embed them in the box output? If export fails or produces outputs we can't decode cleanly in Swift, this is where we stop and decide between (a) downgrading to `yolo11l.pt` (detection only, no seg masks, and update the `/detect` protocol to return empty masks), (b) exporting via `torch.jit.trace` on the underlying model directly, skipping ultralytics' exporter, or (c) staying on HTTP for `/detect` alone and moving to Phase 4. |
| 1 | `tools: add scripts/convert-yolo-to-coreml.py` | Based on spike findings; produces the `.mlmodelc.zip` + SHA-256 |
| 2 | `feat(inference): YOLOBirdDetector Swift wrapper — bounding boxes only` | Letterbox → 640×640; parse boxes/confs/classes; filter class 14 (COCO bird); un-letterbox; NMS at IoU 0.45 |
| 3 | `feat(inference): YOLO segmentation mask decoding` | Parse mask prototypes per spike findings; resize to box size; threshold at 0.5; base64 encode (protocol parity with HTTP). **Skipped if spike chose Path (a)** (downgrade to detection-only). |
| 4 | `test(inference): YOLO preprocessing + NMS + un-letterbox unit tests` | Synthetic inputs with known expected outputs |
| 5 | `feat(inference): wire detect() into CoreMLInferenceClient` | |
| 6 | `feat(manager): add YOLO manifest entry` | |
| 7 | `test(parity): enable test_detect_parity (IoU ≥ 0.95)` | Singles + flocks + no-bird |
| 8 | `refactor: NMS choice — Core ML layer vs Swift impl, pick faster` | Benchmark both, commit decision in the PR message |
| 9 | `perf: YOLO compute-unit benchmark` | Pin best `ModelConfiguration.yolo` |

**Gate:** Flight + keypoints + detect parity green. `/identify` still routes to HTTP (uses YOLO+OSEA; OSEA comes in Phase 4).

### Phase 4 — OSEA + species pipeline (`/identify`) (2 PRs, ~15 commits total)

**Pre-decided split:** Phase 4 ships as **two independent PRs** — 4a (data + support types, no `identify()` wiring) and 4b (OSEA model + pipeline wiring). Both merge without making the app worse because the hybrid routing from Phase 1 keeps `/identify` on HTTP until 4b lands.

#### Phase 4a — Species data layer + support types (1 PR, ~8 commits)

Pure data and pure-function port. No Core ML model, no `identify()` changes.

| # | Commit | What |
|---|---|---|
| 1 | `tools: add scripts/build-species-db.py` | Adds `pinyin_initials` SQL column via pypinyin with `errors="ignore"`; version-pinned `pypinyin` in `tools/requirements.txt`; build-time assertion that `pinyin_initials` is non-empty for every row with non-empty `chinese_simplified` |
| 2 | `feat(data): SpeciesDatabase with readonly GRDB + preload + unit tests` | `DatabaseQueue` with `Configuration.readonly = true`; preload 10964 rows at init |
| 3 | `feat(pipeline): SmartCrop pure function + unit tests` | Direct port of `_smart_crop`; tests include edge-clamped letterbox cases |
| 4 | `feat(pipeline): RegionBounds.swift (generated from avonet_filter.py)` | Build script emits Swift from Python; commit asserts identical content via round-trip test |
| 5 | `feat(pipeline): AvonetFilter.swift — GRDB-backed GPS queries` | Port of `get_species_by_gps`, `get_species_by_country_ebird`, `get_species_by_region_ebird`. Synthetic avonet.db rows for unit tests. |
| 6 | `feat(pipeline): SpeciesFilterChain.swift — mask → softmax → threshold → fallback` | Port of `_get_species_filter_chain` + `predict_from_logits`. Unit tests with fixed logits + fixture species sets. |
| 7 | `feat(manager): add species data manifest entries (bird_reference, avonet, ebird mapping, ebird region lists)` | Four new entries; ModelManager downloads on next launch but none are wired into `CoreMLInferenceClient` yet |
| 8 | `feat(inference): add InferenceConstants.swift with thresholds sourced from Python` | Central constants file (see Section 5) |

**Gate for 4a:** `swift build`, `swift test` pass; `AvonetFilter` unit tests exercise every query method; `SmartCrop` round-trip test matches Python output bit-for-bit on a fixture of 20 box inputs; no native `/identify` path exists yet (still routes to HTTP).

#### Phase 4b — OSEA model + identify() wiring (1 PR, ~7 commits)

Builds on 4a. When 4b merges, `/identify` goes native.

| # | Commit | What |
|---|---|---|
| 1 | `tools: add scripts/convert-osea-to-coreml.py` | ResNet34 `num_classes=11000` → trace → Core ML. Verify output shape. |
| 2 | `feat(inference): OSEAClassifier wrapper with TTA` | vImage Lanczos 224, ImageNet norm, flip-average raw logits, trim to 10964. Unit test against fixed-input asserts ±0.001 vs Python logits on a canonical test image. |
| 3 | `feat(manager): add OSEA manifest entry` | |
| 4 | `feat(inference): wire identify() into CoreMLInferenceClient` | Full pipeline orchestration: RAWLoader → GPSExtractor → YOLO → for each bird: SmartCrop → OSEAClassifier → SpeciesFilterChain → SpeciesDatabase lookup. Removes `notYetImplemented` stub. |
| 5 | `test(parity): enable test_identify_top1 + test_identify_noBird + test_identify_rareSpecies` | Gate #1 identify tests against all 62 relevant fixtures |
| 6 | `test(parity): run Gate #2 rating parity (100-photo folder, aesthetics still HTTP)` | First Gate #2 run — target relaxed match ≥98% (tighter than final because aesthetics is the same backend in both runs) |
| 7 | `perf: OSEA compute-unit benchmark + memory profile` | Verify ANE usage; measure peak RSS during 100-photo run against the 1.5 GB budget from Section 5 |

**Gate for 4b (the big one):** Gate #1 every endpoint green EXCEPT aesthetics; Gate #2 run #1 against 100-photo folder with aesthetics HTTP in both runs — target strict match ≥ 95%, relaxed match ≥ 98%, species ≥ 98%. Memory budget honored.

### Phase 5 — Aesthetics (TOPIQ or replacement) (1 PR, ~7 or ~10 commits)

Highest-uncertainty phase. Starts with a spike.

**Spike (commits 1–2):**
| # | Commit | What |
|---|---|---|
| 1 | `spike: inspect topiq_model package internals` | Report architecture, preprocessing, output range in PR description |
| 2 | `spike: attempt TOPIQ → Core ML conversion` | Success → Path A; failure → Path B |

**Path A — TOPIQ converts:**
| # | Commit | What |
|---|---|---|
| 3a | `tools: add scripts/convert-aesthetics-to-coreml.py` | |
| 4a | `feat(inference): AestheticsModel wrapper (TOPIQ)` | |
| 5a | `feat(inference): wire aesthetics() into CoreMLInferenceClient` | |
| 6a | `feat(manager): add aesthetics manifest entry` | |
| 7a | `test(parity): enable test_aesthetics_parity at ±0.3` | Strict tolerance |

**Path B — TOPIQ swap (NIMA-style ResNet or compound native signal):**
| # | Commit | What |
|---|---|---|
| 3b | `feat(inference): add replacement aesthetics model` | Decision documented in PR |
| 4b | `tools: add conversion script` or `use Vision built-ins` | |
| 5b | `test: Spearman rank-correlation replaces absolute tolerance` | ρ ≥ 0.85 |
| 6b | `feat(rating): recalibrate RatingEngine aesthetics thresholds if range shifted` | `minimumAesthetics` (2.0) and `config.aestheticsThreshold` may shift |
| 7b | `feat(inference): AestheticsModel swap wiring` | |
| 8b | `feat(manager): add replacement model manifest entry` | |
| 9b | `test(parity): enable test_aesthetics_parity (Spearman mode)` | |
| 10b | `test(parity): rerun rating parity with swap` | Gate #2 run #2 |

**Gate:** Gate #1 all endpoints green (incl. aesthetics at applicable tolerance); Gate #2 on 200-photo folder — strict rating match **≥ 90% (floor)**, target 95%; relaxed rating match (±1 star) ≥ 98%; species top-1 ≥ 95%; all other Gate #2 assertions per Section 6. The 90% floor is the acceptance criterion (#5); 95% is the phase target — if the phase lands between 90% and 95%, the phase ships but the result is noted in the PR description and re-checked in Phase 6's real-folder smoke test.

### Phase 6 — Flip default (1 PR, ~5 commits)

Policy change only. All engineering done.

| # | Commit | What |
|---|---|---|
| 1 | `feat(settings): flip InferenceBackendSetting default to .native` | Default-only; existing explicit HTTP choices preserved in `UserDefaults` |
| 2 | `feat(startup): run ModelManager.ensureReady() in background before MainView` | First-launch download sheet; all strings localized in en + zh-Hans |
| 3 | `docs: add "Migrating from HTTP backend" to README` | |
| 4 | `test(parity): rerun both gates against latest shipping manifest` | |
| 5 | `chore: tag v-http-legacy at this commit` | `git tag -a v-http-legacy -m "Last commit with HTTP backend fully present; use for regression bisects"`. Push tag. This tag is the **only** reliable way to A/B test a reported regression post-Phase-7; preserves the ability to answer "was the rating different on this photo before?" without checking out random SHAs. |

**Gate:** Real user folder (≥100 photos) processes end-to-end on native with visually-sensible ratings. "Try on your own photos" checkpoint.

### Phase 7 — Kill Python (1 PR, ~8 commits)

After Phase 6 has been default ≥1 week with no reported regressions.

| # | Commit | What |
|---|---|---|
| 1 | `feat(settings): migrate persisted .http backend choice to .native` | **Must land before the enum change.** On first launch after app update, read the raw persisted value for `InferenceBackendSetting`. If it's `.http` (or anything not matching the new enum), silently set it to `.native` and persist. Custom `Codable` shim lives through Phase 7 — can be deleted in Phase 8+ (or never, it's a 10-line safety net). Without this, Swift `Codable` decoding of the removed enum case throws and users who explicitly chose HTTP either crash their Settings panel or lose their preference silently. **Reviewer-flagged as a critical bug.** |
| 2 | `refactor: remove HTTP backend from InferenceBackendSetting enum` | Toggle becomes internal `nativeOrMock` (test-only boolean). The migration from commit 1 guarantees no user-persisted value decodes to a missing case. |
| 3 | `refactor: delete HTTPInferenceClient.swift, ProcessManager.swift` | Two Swift files gone. Also delete `HTTPInferenceClientTests.swift` if it exists. |
| 4 | `refactor: delete python-server/ directory entirely` | All Python source, tests, requirements.txt |
| 5 | `refactor: update scripts/run-l2.sh to run pure-Swift parity against snapshots` | No more Flask in L2. Uses the golden-file snapshot comparison from Section 6. |
| 6 | `refactor: remove Python hook portions, update CLAUDE.md references, add ARCHS=arm64 to project.yml` | Final cleanup. `ARCHS=arm64` locks the build to Apple Silicon, matching the hardware requirements decision. |
| 7 | `docs: add docs/NN-native-inference-rewrite.md with migration record` | Archive the plan with rollout notes, parity numbers, and any drift discovered post-flip |
| 8 | `test(smoke): end-to-end test with no persisted settings and with .http persisted settings` | Two subtest cases: (a) fresh UserDefaults — app launches clean, uses native default; (b) UserDefaults contains the old `.http` value — migration fires on launch, Settings panel shows native without crashing, folder processing still works. Catches any miss from commit 1. |

**Gate:** `swift build`, `swift test`, `scripts/run-l2.sh`, `scripts/run-l3.sh` all pass; app launches with both fresh and pre-existing-HTTP UserDefaults; processes a folder; shows ratings; zero embedded Python references in the binary (`nm SuperPicky.app/Contents/MacOS/SuperPicky | grep -i python` returns empty); `pgrep python3 superpicky_server` during runtime returns nothing; `grep v-http-legacy $(git tag)` shows the bisect tag from Phase 6 is still present.

### Phase summary

| Phase | Target | PRs | Commits | Gate |
|---|---|---|---|---|
| 0 | Foundation (incl. autoreleasepool prophylactic) | 1 | 6 | Existing tests stay green |
| 1 | Flight (EfficientNet-B3) | 1 | 8 | Parity #1 (flight) |
| 2 | Keypoint (custom ResNet50) | 1 | 8 | Parity #1 (flight + keypoints) |
| 3 | YOLO seg `/detect` (spike-gated) | 1 | 10 | Parity #1 (+ detect) |
| 4a | Species data + pure-function ports | 1 | 8 | `swift test` + unit tests |
| 4b | OSEA model + identify() wiring | 1 | 7 | Parity #1 (all except aesthetics) + Parity #2 run #1 |
| 5 | Aesthetics (spike-gated, Path A or B) | 1 | 7 or 10 | Parity #1 (all) + Parity #2 run #2 |
| 6 | Flip default + legacy tag | 1 | 5 | Real-folder smoke test |
| 7 | Kill Python (incl. settings migration) | 1 | 8 | Everything works without Python; bisect tag preserved |

**Total: 9 PRs (Phases 0, 1, 2, 3, 4a, 4b, 5, 6, 7), 67–70 commits** depending on whether Phase 5 takes Path A (TOPIQ converts, 2-spike + 5 Path A commits = 7) or Path B (TOPIQ swap, 2-spike + 8 Path B commits = 10). **Phase 4 is pre-split** into two PRs (4a: data layer; 4b: OSEA + wiring) to keep each reviewable.

---

## Risks & mitigations

| # | Risk | Severity | Mitigation |
|---|---|---|---|
| 1 | TOPIQ refuses to convert to Core ML (transformer ops unsupported) | High | Phase 5 starts with a spike; user pre-approved swap option. Replacement shifts aesthetics range; rating thresholds recalibrated. |
| 2 | OSEA ResNet34 top-1 drift > 2% on real photos | Medium | Loss audit enforces bit-by-bit preprocessing parity; TTA done on raw logits not probs; temperature 0.9 preserved; Gate #2 catches cross-model drift. |
| 3 | RAW decode differs between rawpy and CGImageSource enough to shift YOLO boxes | Medium | Unifying to Swift actually makes pipeline more consistent than today's mixed decode. Tolerance IoU ≥ 0.95 absorbs small boundary shifts. |
| 4 | Keypoint FP16 on MPS → CoreML precision drift | Medium | Tolerance ±5 px at 416×416 (~1.2% relative); benchmark commit per phase picks best compute unit. |
| 5 | Model download fails on first launch (network, disk, signature) | Low | ModelManager has explicit retry, resume, disk check, signature fallback with user-facing error. |
| 6 | `avonet.db` file corrupts on user's machine | Low | SHA-256 verified on every launch (cheap); re-download on mismatch. |
| 7 | CI parity test flakes due to fixture LFS pull | Low | LFS enabled per `azure-vm` skill; fixtures pinned by SHA. |
| 8 | Phase 4 would be too big to land as one PR | Medium | **Pre-split** into 4a (data + pure functions, 8 commits) and 4b (OSEA model + `identify()` wiring, 7 commits). Both are independently reviewable and land in sequence; 4a ships without touching production `/identify` routing. See Section 7 Phase 4a/4b. |
| 9 | Pinyin drift between preen runtime and pre-computed column | Low | `pypinyin` version pinned in tool; build-time assertion non-empty for every cn_name; regeneration checked by CI. |
| 10 | `MLModel` thread-safety assumptions wrong under load | Low | Apple documents thread-safety; fallback is actor isolation with serial dispatch queue (performance hit, not correctness). |
| 11 | Neural Engine queue serialization negates `async let` parallelism | Low | Perf concern only. Phase benchmarks tune compute-unit per model; could end up with OSEA on ANE, others on GPU. |
| 12 | Stale plan file from prior session misleads reviewers | Low | Already removed; plan uses a fresh filename with the date. |
| 13 | Production regression goes unnoticed after Phase 7 because there's no telemetry | Low (by choice) | **Deliberate non-feature.** SuperPicky is a local pro tool with a single primary user (the author); adding crash reporting or remote telemetry adds privacy surface area, dependencies (Sentry, Bugsnag, or home-grown), and ongoing maintenance that isn't justified by the user base size. Regression detection relies on (a) the author noticing bad ratings on their own photos during the 1-week Phase 6 → Phase 7 bake, (b) the `v-http-legacy` git tag enabling retroactive A/B bisects, (c) `os.Logger` local logs on the user's machine which the author can inspect via `log stream --predicate 'subsystem == "com.superpicky.mac"'`. If SuperPicky's user base grows to include non-author users, adding telemetry becomes a separate decision documented in a follow-up design. |
| 14 | `.mlmodelc` downloaded files get `com.apple.quarantine` xattr set and trip Gatekeeper dialogs | Low | ModelManager clears the xattr after checksum verification. Tested in Phase 6 on a fresh user-account install. |
| 15 | Memory pressure during long-folder runs on 8 GB Macs | Medium | `autoreleasepool` wrap in per-photo loop (Phase 0 commit); Gate #2 asserts RSS ≤ 1.5 GB after 500 photos; full budget in Section 5 Memory subsection. |
| 16 | Phase 7 deleting HTTP backend breaks users with persisted `.http` setting | Medium | Phase 7 commit 1 migrates `.http` → `.native` before the enum change; Phase 7 commit 8 adds smoke tests for both fresh and pre-existing UserDefaults states. |

---

## Out of scope

- Rewriting `preen` itself
- New culling features or UI changes
- Changes to `RatingEngine`, `BurstDetector`, `ExposureDetector` (already native Swift)
- Changes to XMP output or Export service (already native)
- Adding new models (focus-point detector, etc.) — column exists but unused
- iCloud Photos library integration (that's preen's domain)
- Changing the default `RatingEngine.Config` thresholds
- Changing the `.report.db` schema except for the `databaseName` parameter addition in `PipelineCoordinator.process`

---

## Open questions for implementation plan

Most prior open questions have been converted to explicit spike commits in Section 7 rather than deferred. The remaining questions that writing-plans should address:

1. ~~PartLocalizer state-dict key layout~~ — **now Phase 2 commit 0 (spike)**. Explicit commit in Section 7.
2. ~~ultralytics YOLO seg export format~~ — **now Phase 3 commit 0 (spike)**. Explicit commit in Section 7.
3. **Does TOPIQ trace cleanly? What's the output range?** Remains a Phase 5 commit-0 spike; Phase 5 branches to Path A or Path B based on the answer. The spike is already in Section 7 Phase 5 commits 1–2 as `spike: inspect topiq_model package internals` and `spike: attempt TOPIQ → Core ML conversion`.
4. `avonet.db` exact row counts and schema — will be verified in Phase 4a commit 5 (`AvonetFilter.swift` with GRDB queries). A no-op if the reviewer has already inspected it (the schema matches `avonet_filter.py:206-217` and `226-241`).
5. Is there an existing `ModelManifest.loadBundled()` helper pattern in SuperPicky? — likely no (this is new surface area). writing-plans should confirm by searching the codebase and either reuse or invent.
6. `MockInferenceClientForUI` is decided: it stays unchanged (Section 2 "MockInferenceClientForUI adaptation"). No open question.

---

## References

### Source files audited

**`python-server/` (the current web service):**
- `superpicky_server.py` — Flask entry, 5 endpoints
- `inference/detector.py` — YOLO wrapper (file-based, unused by Swift pipeline)
- `inference/aesthetics.py` — TOPIQ wrapper
- `inference/keypoints.py` — wraps legacy `core/keypoint_detector.py`
- `inference/flight.py` — wraps legacy `core/flight_detector.py`
- `inference/species.py` — delegates to preen, post-processes results
- `inference/device.py` — MPS/CUDA/CPU detection

**`~/projects/preen/src/preen/` (the blueprint):**
- `detector.py` — YOLO detect, smart crop, filter chain orchestration
- `folder.py` — `load_folder_image`, `extract_gps`, `reverse_geocode`, `write_iptc`
- `birdid/osea_classifier.py` — ResNet34 with TTA, bird info lookup
- `birdid/avonet_filter.py` — SQL queries + `REGION_BOUNDS` + country detection
- `birdid/data/bird_reference.sqlite` — 10964-class metadata
- `birdid/data/ebird_classid_mapping.json` — eBird code → class ID
- `birdid/data/offline_ebird_data/` — 144 region species files

**`~/projects/SuperPicky/core/` (legacy Python, used by python-server for keypoints + flight):**
- `keypoint_detector.py` — `PartLocalizer` architecture, FP16 inference, 416×416 input
- `flight_detector.py` — EfficientNet-B3 with custom head, 384×384 input

**`apps/mac-client/SuperPickyApp/` (the Swift side):**
- `InferenceClient.swift` — the protocol (stays unchanged)
- `HTTPInferenceClient.swift` — current impl (deleted in Phase 7)
- `PipelineCoordinator.swift` — consumer (unchanged)
- `DetectionResult.swift` — response types (unchanged)
- `ProcessManager.swift` — Python subprocess launcher (deleted in Phase 7)

### Documents

- `CLAUDE.md` — project conventions, quality gates, retrospective
- `~/.claude/CLAUDE.md` — user-global preferences (plan first, verify autonomously, etc.)

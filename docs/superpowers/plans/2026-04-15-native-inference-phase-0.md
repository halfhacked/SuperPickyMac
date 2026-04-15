# Native Inference Rewrite — Phase 0 (Foundation) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lay down the scaffolding the next 8 phases will build on: a new `SuperPickyInference` SPM sub-target, `ModelManifest` + `ModelManager` stubs, an autoreleasepool prophylactic wrap of the per-photo loop, a Settings toggle for inference backend (HTTP only this phase, native grayed out with a coming-soon note), a Parity test target shell, and an optional `databaseName` parameter on `PipelineCoordinator.process` that the Parity tests will need in Phase 4b. No new model, no new endpoint, no user-visible behavior change.

**Architecture:** One new SPM library target (`SuperPickyInference`) separate from the existing `SuperPicky` executable target. The executable target depends on the library target. The library target is pure-logic, zero AppKit imports. All new code either lives in that target or extends existing Swift files in `SuperPickyApp/`. The Parity test target sits under `SuperPickyTests/Parity/` with a single empty `ParityTestBase.swift` and zero active tests; it becomes the home for Gate #1 and Gate #2 in later phases.

**Tech Stack:** Swift 5.10 + SPM + Xcode 15 + xcodegen + GRDB 7.0 + Swift Testing for new unit tests (matching the existing `SuperPickyTests/` convention). macOS 14+ deployment target.

**Reference:** [docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md](docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md) — this plan implements Phase 0 from Section 7 of that spec.

**Scope:** 6 commits. After merge the app still runs exactly as before; no user-visible change; all existing tests still pass.

---

## File Inventory

### Files created

| File | Purpose |
|---|---|
| `apps/mac-client/SuperPickyInference/InferenceConstants.swift` | Central enum with all Python-sourced magic numbers (thresholds, input sizes, ImageNet norm, bird class ID, OSEA temperature, NMS IoU). Read by every model wrapper in later phases. |
| `apps/mac-client/SuperPickyInference/Download/ModelManifest.swift` | `ModelManifest` + `ModelEntry` Codable types. `loadBundled()` factory that reads `manifest.json` from the SuperPickyInference bundle resources. |
| `apps/mac-client/SuperPickyInference/Download/ModelManager.swift` | Actor with `ensureReady()` method. Empty-manifest fast path returns `.ready` immediately. Phase 1+ will add real downloading. |
| `apps/mac-client/SuperPickyInference/Resources/manifest.json` | Bundled stub JSON with zero-entry models array and `"version": 1`. |
| `apps/mac-client/SuperPickyApp/InferenceBackendSetting.swift` | `InferenceBackend` enum (`.http`, `.native`) + helper for UI display. Small file — lives in SuperPickyApp rather than SuperPickyInference because it's a user-preference type. |
| `apps/mac-client/SuperPickyTests/Inference/InferenceConstantsTests.swift` | Smoke test: import `SuperPickyInference`, read one constant, assert expected value. Proves the module builds and links. |
| `apps/mac-client/SuperPickyTests/Inference/ModelManifestTests.swift` | Unit tests: decoding the bundled stub, empty-array check, round-trip encoding. |
| `apps/mac-client/SuperPickyTests/Inference/ModelManagerTests.swift` | Unit tests: `ensureReady()` with empty manifest returns `.ready`; state observation stream emits `.ready`. |
| `apps/mac-client/SuperPickyTests/Parity/ParityTestBase.swift` | Empty `XCTestCase` subclass. Test methods come in later phases. Marked with a skip reason so no test actually runs in Phase 0. |

### Files modified

| File | Lines | Change |
|---|---|---|
| `apps/mac-client/Package.swift` | 11–25 | Add `.target(name: "SuperPickyInference", ...)` and make `SuperPicky` executable target depend on it; `SuperPickyTests` also depends on it. |
| `apps/mac-client/project.yml` | 13–31 | Add new `SuperPickyInference` xcodegen framework target; make `SuperPicky` depend on it. |
| `apps/mac-client/SuperPickyApp/CullingConfig.swift` | 49–91 | Add `var inferenceBackend: InferenceBackend { didSet { save() } }` with persistence to `UserDefaults`. |
| `apps/mac-client/SuperPickyApp/AdvancedTab.swift` | 35–41 | Replace the existing `Backend` section (port field) with a new section containing: the port field (unchanged) AND a `Picker` for inference backend (HTTP only in this phase, caption note about native coming later). |
| `apps/mac-client/SuperPickyApp/PipelineCoordinator.swift` | 55–103 | Two separate commits touch this file. (Task 4) Add a memory-budget comment block + `await Task.yield()` at the end of the per-photo loop iteration as an ARC-release prophylactic. (Task 6) Add optional `databaseName: String = ".report.db"` parameter to `process(...)` and thread it through to `ReportDatabase(folderPath: folder, name: databaseName)` — this also requires a one-line addition to `ReportDatabase`'s initializer signature. |
| `apps/mac-client/SuperPickyApp/ReportDatabase.swift` | (wherever init lives) | Add `name: String = ".report.db"` parameter to the existing `init(folderPath:)` → `init(folderPath:name:)`. Existing callers unchanged due to default value. |
| `apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings` | end of file | Add new keys: "Inference Backend", "HTTP (Python server)", "Native Core ML (coming in a future release)". |
| `apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings` | end of file | Same keys, Chinese translations. |

### Files NOT changed (and why)

| File | Reason |
|---|---|
| `apps/mac-client/SuperPickyApp/HTTPInferenceClient.swift` | Stays unchanged this phase — still the only real `InferenceClient` implementation. |
| `apps/mac-client/SuperPickyApp/InferenceClient.swift` | Protocol unchanged; `SuperPickyInference` imports from `SuperPickyApp` *eventually* (in Phase 1 when `CoreMLInferenceClient` is introduced), not in Phase 0. |
| `apps/mac-client/SuperPickyApp/ProcessManager.swift` | Python subprocess launcher — keep running. |
| `python-server/*` | No changes. Still the sole inference backend. |
| Existing `SuperPickyTests/Core/`, `BDD/`, `Data/` | None modified. Existing tests must keep passing. |

---

## Critical Context for the Implementer

Before starting, read these files. They inform almost every task below:

- [apps/mac-client/Package.swift](apps/mac-client/Package.swift) — current SPM layout; single executable target
- [apps/mac-client/project.yml](apps/mac-client/project.yml) — xcodegen source of truth for the `.xcodeproj`
- [apps/mac-client/SuperPickyApp/CullingConfig.swift:49-91](apps/mac-client/SuperPickyApp/CullingConfig.swift:49) — `@Observable final class CullingConfig` with `didSet` persistence pattern
- [apps/mac-client/SuperPickyApp/AdvancedTab.swift](apps/mac-client/SuperPickyApp/AdvancedTab.swift) — existing Settings tab where the toggle goes
- [apps/mac-client/SuperPickyApp/PipelineCoordinator.swift:55-103](apps/mac-client/SuperPickyApp/PipelineCoordinator.swift:55) — per-photo `for fileURL in files` loop
- CLAUDE.md retrospective: "New Swift files must be added to both `Package.swift` AND the `.xcodeproj`" — every file-creation task below regenerates the xcodeproj via xcodegen
- CLAUDE.md retrospective: "Localize all new UI strings" — every new `Text` must use `config.localized("key")` AND be added to both `.strings` files

**Build commands you will use throughout:**

```bash
cd apps/mac-client
swift build                                     # SPM build; fast; doesn't catch xcodeproj drift
swift test                                      # SPM tests
xcodegen                                        # Regenerate .xcodeproj from project.yml
xcodebuild -project SuperPicky.xcodeproj \
  -scheme SuperPicky -configuration Debug build  # Full Xcode build
```

**Important:** both `swift build` AND `xcodebuild` must pass. CI uses `xcodebuild`; SPM-only developers use `swift build`. They have different file registries.

---

## Task 1: Create SuperPickyInference SPM target with InferenceConstants

Creates the new sub-target and lands the first real file (`InferenceConstants.swift`) as its content. Having a real file avoids the "empty target" edge case in SPM and also delivers the Section 5 requirement for a central constants file.

**Files:**
- Create: `apps/mac-client/SuperPickyInference/InferenceConstants.swift`
- Create: `apps/mac-client/SuperPickyTests/Inference/InferenceConstantsTests.swift`
- Modify: `apps/mac-client/Package.swift`
- Modify: `apps/mac-client/project.yml`

### Steps

- [ ] **Step 1.1: Create the directory for the new target**

```bash
mkdir -p apps/mac-client/SuperPickyInference
mkdir -p apps/mac-client/SuperPickyTests/Inference
```

No output expected.

- [ ] **Step 1.2: Write the failing test first (TDD)**

Create `apps/mac-client/SuperPickyTests/Inference/InferenceConstantsTests.swift`:

```swift
import Testing
@testable import SuperPickyInference

@Suite("InferenceConstants")
struct InferenceConstantsTests {
    @Test("OSEA regional species threshold matches python-server/inference/species.py")
    func regionalThreshold() {
        #expect(InferenceConstants.regionalSpeciesThreshold == 80.0)
    }

    @Test("OSEA global species threshold matches python-server/inference/species.py")
    func globalThreshold() {
        #expect(InferenceConstants.globalSpeciesThreshold == 90.0)
    }

    @Test("OSEA temperature matches preen/birdid/osea_classifier.py")
    func temperature() {
        #expect(InferenceConstants.oseaTemperature == 0.9)
    }

    @Test("OSEA class count is 10964")
    func numClasses() {
        #expect(InferenceConstants.oseaNumClasses == 10964)
    }

    @Test("YOLO bird class ID is 14 (COCO)")
    func birdClassID() {
        #expect(InferenceConstants.yoloBirdClassID == 14)
    }

    @Test("ImageNet mean matches torchvision default")
    func imageNetMean() {
        #expect(InferenceConstants.imageNetMean == SIMD3<Float>(0.485, 0.456, 0.406))
    }

    @Test("ImageNet std matches torchvision default")
    func imageNetStd() {
        #expect(InferenceConstants.imageNetStd == SIMD3<Float>(0.229, 0.224, 0.225))
    }
}
```

- [ ] **Step 1.3: Run the test — expected to fail with missing module**

```bash
cd apps/mac-client && swift test --filter InferenceConstantsTests
```

Expected: build failure. Error message along the lines of `no such module 'SuperPickyInference'`. This is the expected TDD fail state — the target doesn't exist yet.

- [ ] **Step 1.4: Create `InferenceConstants.swift` with all constants**

Create `apps/mac-client/SuperPickyInference/InferenceConstants.swift`:

```swift
// InferenceConstants.swift
//
// Central source of every Python-sourced magic number the native inference
// pipeline needs. Every constant cites its Python source so a future drift
// check is a single-file diff.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 4A "Model hyperparameters" for the complete audit.

import Foundation
import simd

public enum InferenceConstants {
    // MARK: OSEA / species classifier
    // Source: python-server/inference/species.py:7-8
    public static let regionalSpeciesThreshold: Float = 80.0
    public static let globalSpeciesThreshold: Float = 90.0

    // Source: preen/birdid/osea_classifier.py:104
    public static let oseaTemperature: Float = 0.9

    // Source: preen/birdid/osea_classifier.py:177
    // Model outputs 11000 logits; we trim to the 10964 used species.
    public static let oseaNumClasses = 10964

    // Source: preen/birdid/osea_classifier.py:98
    public static let oseaInputSize = 224

    // Source: preen/birdid/osea_classifier.py:231 (dead filter in practice, preserved for parity)
    public static let oseaMinConfidencePercent: Float = 0.3

    // MARK: YOLO
    // Source: preen/detector.py:11 (COCO dataset bird class)
    public static let yoloBirdClassID = 14

    // Source: ultralytics defaults
    public static let yoloInputSize = 640
    public static let yoloNMSThreshold: Float = 0.45
    public static let yoloConfThreshold: Float = 0.25

    // MARK: Keypoint
    // Source: ~/projects/SuperPicky/core/keypoint_detector.py:71-72
    public static let keypointInputSize = 416
    public static let keypointVisibilityThreshold: Float = 0.3

    // MARK: Flight
    // Source: ~/projects/SuperPicky/core/flight_detector.py:38-39
    public static let flightInputSize = 384
    public static let flightThreshold: Float = 0.5

    // MARK: Smart crop
    // Source: preen/detector.py:76
    public static let smartCropPaddingFactor: Float = 1.15

    // MARK: ImageNet normalization (standard torchvision)
    public static let imageNetMean: SIMD3<Float> = SIMD3<Float>(0.485, 0.456, 0.406)
    public static let imageNetStd: SIMD3<Float> = SIMD3<Float>(0.229, 0.224, 0.225)
}
```

- [ ] **Step 1.5: Update `Package.swift` to add the SuperPickyInference target**

Replace the entire `targets` array with:

```swift
    targets: [
        .target(
            name: "SuperPickyInference",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "SuperPickyInference"
        ),
        .executableTarget(
            name: "SuperPicky",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SuperPickyInference",
            ],
            path: "SuperPickyApp",
            exclude: ["en.lproj", "zh-Hans.lproj"]
        ),
        .testTarget(
            name: "SuperPickyTests",
            dependencies: [
                "SuperPicky",
                "SuperPickyInference",
            ],
            path: "SuperPickyTests"
        ),
    ]
```

- [ ] **Step 1.6: Run `swift build` to verify SPM layout**

```bash
cd apps/mac-client && swift build
```

Expected: `Build complete!`. If it errors about missing `InferenceConstants.swift`, check the file path. If it errors about circular dependencies, double-check that `SuperPickyInference` does NOT depend on `SuperPicky`.

- [ ] **Step 1.7: Run the unit test — should now pass**

```bash
cd apps/mac-client && swift test --filter InferenceConstantsTests
```

Expected: `Test Suite 'InferenceConstants' passed` with 7 tests passing.

- [ ] **Step 1.8: Update `project.yml` to add the xcodegen target**

Add the new target **above** the existing `SuperPicky` target in the `targets:` section, and add a dependency from `SuperPicky` to it:

```yaml
targets:
  SuperPickyInference:
    type: framework
    platform: macOS
    sources:
      - path: SuperPickyInference
    dependencies:
      - package: GRDB
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.superpicky.SuperPickyInference
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDevelopmentRegion: en
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: NO
        SKIP_INSTALL: NO
        DEFINES_MODULE: YES

  SuperPicky:
    type: application
    platform: macOS
    sources:
      - path: SuperPickyApp
    postBuildScripts:
      - name: "Bundle Python Server"
        script: |
          SERVER_SRC="${PROJECT_DIR}/../../python-server"
          SERVER_DST="${BUILT_PRODUCTS_DIR}/${PRODUCT_NAME}.app/Contents/Resources/python-server"
          rm -rf "$SERVER_DST"
          mkdir -p "$SERVER_DST/inference"
          cp "$SERVER_SRC/superpicky_server.py" "$SERVER_DST/"
          cp "$SERVER_SRC/requirements.txt" "$SERVER_DST/"
          cp "$SERVER_SRC/inference/"*.py "$SERVER_DST/inference/"
    dependencies:
      - package: GRDB
      - target: SuperPickyInference
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.superpicky.SuperPicky
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDevelopmentRegion: en
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        MARKETING_VERSION: "0.0.2"
        CURRENT_PROJECT_VERSION: "2"
```

- [ ] **Step 1.9: Regenerate the xcodeproj and build**

```bash
cd apps/mac-client && xcodegen && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **` at the end. If xcodegen errors about the framework target, check the indentation of `project.yml` — YAML is whitespace-sensitive.

- [ ] **Step 1.10: Commit**

```bash
git add apps/mac-client/Package.swift \
        apps/mac-client/project.yml \
        apps/mac-client/SuperPickyInference/InferenceConstants.swift \
        apps/mac-client/SuperPickyTests/Inference/InferenceConstantsTests.swift
git commit -m "feat(spm): add SuperPickyInference target with InferenceConstants

New SPM library target + xcodegen framework target for the native
inference code. InferenceConstants centralizes every Python-sourced
magic number (thresholds, input sizes, ImageNet norm) so future drift
checks are a single-file diff. Empty until Phase 1 adds the first
model wrapper."
```

---

## Task 2: ModelManifest type + bundled stub manifest.json

Defines the Codable schema for the manifest file ModelManager will read in Phase 1+. Ships a zero-entry stub so `ensureReady()` is a valid no-op until real models arrive.

**Files:**
- Create: `apps/mac-client/SuperPickyInference/Download/ModelManifest.swift`
- Create: `apps/mac-client/SuperPickyInference/Resources/manifest.json`
- Create: `apps/mac-client/SuperPickyTests/Inference/ModelManifestTests.swift`
- Modify: `apps/mac-client/Package.swift` (add `resources: [.process("Resources/manifest.json")]`)

### Steps

- [ ] **Step 2.1: Create the Download subdirectory and Resources subdirectory**

```bash
mkdir -p apps/mac-client/SuperPickyInference/Download
mkdir -p apps/mac-client/SuperPickyInference/Resources
```

- [ ] **Step 2.2: Write the failing test**

Create `apps/mac-client/SuperPickyTests/Inference/ModelManifestTests.swift`:

```swift
import Foundation
import Testing
@testable import SuperPickyInference

@Suite("ModelManifest")
struct ModelManifestTests {
    @Test("loadBundled returns a manifest with version 1")
    func loadBundledVersion() throws {
        let manifest = try ModelManifest.loadBundled()
        #expect(manifest.version == 1)
    }

    @Test("Phase 0 stub manifest has zero model entries")
    func emptyModels() throws {
        let manifest = try ModelManifest.loadBundled()
        #expect(manifest.models.isEmpty)
    }

    @Test("ModelEntry decodes from JSON with all required fields")
    func decodeEntry() throws {
        let json = """
        {
          "id": "test-model",
          "filename": "test.mlmodelc.zip",
          "url": "https://example.com/test.mlmodelc.zip",
          "sha256": "abc123",
          "sizeBytes": 1024,
          "installPath": "Models/test.mlmodelc"
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(ModelEntry.self, from: json)
        #expect(entry.id == "test-model")
        #expect(entry.filename == "test.mlmodelc.zip")
        #expect(entry.sizeBytes == 1024)
        #expect(entry.installPath == "Models/test.mlmodelc")
    }

    @Test("Manifest round-trips through JSON encode/decode")
    func roundTrip() throws {
        let original = ModelManifest(
            version: 1,
            models: [
                ModelEntry(
                    id: "m1", filename: "m1.zip",
                    url: "https://x.com/m1.zip", sha256: "def",
                    sizeBytes: 2048, installPath: "Models/m1.mlmodelc"
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.models.count == 1)
        #expect(decoded.models[0].id == "m1")
    }
}
```

- [ ] **Step 2.3: Run the test — expected to fail with missing types**

```bash
cd apps/mac-client && swift test --filter ModelManifestTests
```

Expected: build failure — `cannot find 'ModelManifest' in scope`, `cannot find 'ModelEntry' in scope`. Expected TDD state.

- [ ] **Step 2.4: Create `ModelManifest.swift`**

Create `apps/mac-client/SuperPickyInference/Download/ModelManifest.swift`:

```swift
// ModelManifest.swift
//
// The manifest of model files the app needs. Bundled in the app at build
// time (covered by the code signature), lists every downloadable artifact
// with SHA-256 for integrity verification.

import Foundation

public struct ModelManifest: Codable, Sendable {
    public let version: Int
    public let models: [ModelEntry]

    public init(version: Int, models: [ModelEntry]) {
        self.version = version
        self.models = models
    }

    public enum LoadError: Error, CustomStringConvertible {
        case resourceNotFound
        case decodingFailed(underlying: Error)

        public var description: String {
            switch self {
            case .resourceNotFound:
                return "manifest.json not found in SuperPickyInference bundle resources"
            case .decodingFailed(let underlying):
                return "manifest.json failed to decode: \(underlying)"
            }
        }
    }

    /// Loads the bundled manifest.json from the SuperPickyInference module bundle.
    /// Throws `LoadError.resourceNotFound` if the resource is missing (build config issue),
    /// or `LoadError.decodingFailed` if the JSON is malformed.
    public static func loadBundled() throws -> ModelManifest {
        guard let url = Bundle.module.url(forResource: "manifest", withExtension: "json") else {
            throw LoadError.resourceNotFound
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch let error as DecodingError {
            throw LoadError.decodingFailed(underlying: error)
        }
    }
}

public struct ModelEntry: Codable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let url: String
    public let sha256: String
    public let sizeBytes: Int
    public let installPath: String

    public init(
        id: String,
        filename: String,
        url: String,
        sha256: String,
        sizeBytes: Int,
        installPath: String
    ) {
        self.id = id
        self.filename = filename
        self.url = url
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
        self.installPath = installPath
    }
}
```

- [ ] **Step 2.5: Create the stub manifest.json**

Create `apps/mac-client/SuperPickyInference/Resources/manifest.json`:

```json
{
  "version": 1,
  "models": []
}
```

- [ ] **Step 2.6: Update `Package.swift` to include resources in the target**

Replace the `SuperPickyInference` target definition with:

```swift
        .target(
            name: "SuperPickyInference",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "SuperPickyInference",
            resources: [
                .process("Resources/manifest.json"),
            ]
        ),
```

- [ ] **Step 2.7: Update `project.yml` to include resources**

Change the `SuperPickyInference` target's `sources` section from:

```yaml
    sources:
      - path: SuperPickyInference
```

to:

```yaml
    sources:
      - path: SuperPickyInference
        excludes:
          - Resources
      - path: SuperPickyInference/Resources
        type: folder
        buildPhase: resources
```

- [ ] **Step 2.8: Regenerate xcodeproj**

```bash
cd apps/mac-client && xcodegen
```

Expected: silent success.

- [ ] **Step 2.9: Run `swift build`**

```bash
cd apps/mac-client && swift build
```

Expected: `Build complete!`.

- [ ] **Step 2.10: Run the test — should pass**

```bash
cd apps/mac-client && swift test --filter ModelManifestTests
```

Expected: 4 tests passing.

- [ ] **Step 2.11: Run xcodebuild to verify resources copy correctly**

```bash
cd apps/mac-client && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2.12: Commit**

```bash
git add apps/mac-client/Package.swift \
        apps/mac-client/project.yml \
        apps/mac-client/SuperPickyInference/Download/ModelManifest.swift \
        apps/mac-client/SuperPickyInference/Resources/manifest.json \
        apps/mac-client/SuperPickyTests/Inference/ModelManifestTests.swift
git commit -m "feat(manifest): add ModelManifest type + bundled stub manifest.json

Codable schema for the model manifest file ModelManager will read in
Phase 1+. Ships a zero-entry stub so ensureReady() is a valid no-op
until real models arrive."
```

---

## Task 3: ModelManager actor with ensureReady()

Actor-based manager. In Phase 0 it has the full state machine + `observe()` stream API, but `ensureReady()` short-circuits for empty manifests without any network calls. Phase 1+ adds real download logic.

**Files:**
- Create: `apps/mac-client/SuperPickyInference/Download/ModelManager.swift`
- Create: `apps/mac-client/SuperPickyTests/Inference/ModelManagerTests.swift`

### Steps

- [ ] **Step 3.1: Write the failing test**

Create `apps/mac-client/SuperPickyTests/Inference/ModelManagerTests.swift`:

```swift
import Foundation
import Testing
@testable import SuperPickyInference

@Suite("ModelManager")
struct ModelManagerTests {
    @Test("ensureReady() on empty manifest returns .ready without errors")
    func emptyManifestReady() async throws {
        let manifest = ModelManifest(version: 1, models: [])
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superpicky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = ModelManager(manifest: manifest, rootDir: tmpDir)
        try await manager.ensureReady()

        let state = await manager.state
        switch state {
        case .ready:
            break // pass
        default:
            Issue.record("Expected .ready, got \(state)")
        }
    }

    @Test("Initial state is .notStarted")
    func initialState() async {
        let tmpDir = FileManager.default.temporaryDirectory
        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: tmpDir
        )
        let state = await manager.state
        switch state {
        case .notStarted:
            break // pass
        default:
            Issue.record("Expected .notStarted, got \(state)")
        }
    }

    @Test("ensureReady() is idempotent on empty manifest")
    func idempotent() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("superpicky-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: tmpDir
        )
        try await manager.ensureReady()
        try await manager.ensureReady()   // second call must not throw
        let state = await manager.state
        if case .ready = state { /* pass */ } else {
            Issue.record("Expected .ready after second ensureReady, got \(state)")
        }
    }

    @Test("observe() stream emits the current state and subsequent changes")
    func observeStream() async throws {
        let manager = ModelManager(
            manifest: ModelManifest(version: 1, models: []),
            rootDir: FileManager.default.temporaryDirectory
        )

        // Start observing before ensureReady
        let streamTask = Task {
            var seenReady = false
            for await state in await manager.observe() {
                if case .ready = state {
                    seenReady = true
                    break
                }
            }
            return seenReady
        }

        try await manager.ensureReady()
        let result = await streamTask.value
        #expect(result == true)
    }
}
```

- [ ] **Step 3.2: Run the test — expected to fail with missing type**

```bash
cd apps/mac-client && swift test --filter ModelManagerTests
```

Expected: build failure — `cannot find 'ModelManager' in scope`.

- [ ] **Step 3.3: Create `ModelManager.swift`**

Create `apps/mac-client/SuperPickyInference/Download/ModelManager.swift`:

```swift
// ModelManager.swift
//
// Actor that ensures the model files listed in a manifest are present on
// disk. In Phase 0 the happy path is "manifest is empty → state.ready
// immediately." Phase 1+ adds real download, checksum verification, and
// atomic install.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 3 "Model download manager" for the full design.

import Foundation

public actor ModelManager {

    // MARK: - Public state

    public enum State: Sendable {
        case notStarted
        case downloading(progress: Double, currentFile: String)
        case verifying(file: String)
        case installing(file: String)
        case ready
        case failed(Error)
    }

    public private(set) var state: State = .notStarted

    // MARK: - Private state

    private let manifest: ModelManifest
    private let rootDir: URL
    private var observers: [AsyncStream<State>.Continuation] = []

    // MARK: - Init

    public init(manifest: ModelManifest, rootDir: URL) {
        self.manifest = manifest
        self.rootDir = rootDir
    }

    // MARK: - Public API

    /// Ensures every manifest entry is on disk and verified.
    /// Idempotent — safe to call on every app launch.
    ///
    /// Phase 0 behavior: if the manifest is empty, immediately transitions
    /// to `.ready` and emits that state to observers. No network, no disk
    /// writes. Phase 1+ will add real download/verify/install.
    public func ensureReady() async throws {
        if manifest.models.isEmpty {
            setState(.ready)
            return
        }

        // Phase 1+ replaces this fatalError with real download logic.
        // This fatalError is intentional — it makes it impossible to ship
        // Phase 0 with a non-empty manifest without also shipping the
        // download code. The bundled stub manifest has zero entries, so
        // this line is unreachable in Phase 0.
        fatalError("ModelManager cannot download real models until Phase 1")
    }

    /// Returns an `AsyncStream` that emits every state change.
    /// The first emission is always the current state. The stream finishes
    /// when the actor transitions to `.ready`.
    public func observe() -> AsyncStream<State> {
        AsyncStream { continuation in
            // Emit current state immediately so the observer doesn't have
            // to guess what it missed.
            continuation.yield(state)
            observers.append(continuation)
            // No onTermination cleanup: Phase 0 streams always finish via
            // setState(.ready) → continuation.finish(). Phase 1+ may add
            // token-based removal when multiple observers are expected.
        }
    }

    // MARK: - Private helpers

    private func setState(_ newState: State) {
        state = newState
        for continuation in observers {
            continuation.yield(newState)
        }
        if case .ready = newState {
            // terminate streams after ready so observers don't wait forever
            for continuation in observers {
                continuation.finish()
            }
            observers.removeAll()
        }
    }
}
```

**Note on observer cleanup:** Phase 0 relies on `setState(.ready)` → `continuation.finish()` as the only termination path. Because `ensureReady()` on an empty manifest always reaches `.ready`, every observer is finished cleanly. Phase 1+ will add a token-based remove API when the manager needs to support cancellation mid-download.

- [ ] **Step 3.4: Run `swift build`**

```bash
cd apps/mac-client && swift build
```

Expected: `Build complete!`.

- [ ] **Step 3.5: Run the test — should pass**

```bash
cd apps/mac-client && swift test --filter ModelManagerTests
```

Expected: 4 tests passing. If the `observeStream` test hangs, the ready-state termination in `setState` isn't firing — debug `setState` first.

- [ ] **Step 3.6: Run xcodebuild**

```bash
cd apps/mac-client && xcodegen && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3.7: Commit**

```bash
git add apps/mac-client/SuperPickyInference/Download/ModelManager.swift \
        apps/mac-client/SuperPickyTests/Inference/ModelManagerTests.swift
git commit -m "feat(manager): add ModelManager actor with ensureReady() empty-manifest fast path

Actor with State machine (.notStarted, .downloading, .verifying,
.installing, .ready, .failed) and observe() stream. Phase 0 only
implements the empty-manifest path: if no models in the manifest,
transition immediately to .ready. Phase 1+ replaces the fatalError
with real download/verify/install logic."
```

---

## Task 4: Per-iteration ARC release point in the photo loop

Prophylactic memory scaffolding. The naive "wrap the loop body in `autoreleasepool { ... }`" doesn't work because the loop body is async — `autoreleasepool` only scopes synchronous work, and objects can survive across `await` suspension points. The real memory win comes in Phase 2 where each model wrapper's synchronous `predict()` call gets its own proper `autoreleasepool { ... }` block.

What Phase 0 does now is the lightest possible thing that matters: add a `Task.yield()` at the end of each iteration so the runtime loop cycles, giving ARC a scheduled chance to release temporaries before the next iteration allocates more. And add a doc comment explaining that Phase 2 will add the real sync-scope pools inside model wrappers.

This is a single-line behavioral change + doc comment. Trivial.

**Files:**
- Modify: `apps/mac-client/SuperPickyApp/PipelineCoordinator.swift:55-103`

No new test — this has no observable behavior change in Phase 0. The real memory assertion (RSS ≤ 1.5 GB after 500 photos) lands as Gate #2 in Phase 4b per the spec.

### Steps

- [ ] **Step 4.1: Read the current loop end to locate the insertion point**

```bash
grep -n "await onPhotoProcessed" apps/mac-client/SuperPickyApp/PipelineCoordinator.swift
```

Expected: one match around line 102 (the last statement inside the `for fileURL in files` body).

- [ ] **Step 4.2: Add a documentation block at the top of the `process` method body and a `Task.yield()` at the end of the loop iteration**

Find:

```swift
        totalCount = files.count
        processedCount = 0

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
```

Replace with:

```swift
        totalCount = files.count
        processedCount = 0

        // Memory budget note: Phase 2+ model wrappers add synchronous
        // `autoreleasepool { ... }` blocks inside their predict() methods to
        // release MLMultiArray/MLFeatureProvider temporaries at each photo
        // boundary. Here in Phase 0 we cycle the runtime loop once per
        // iteration via Task.yield() below so ARC gets a scheduled chance
        // to release temporaries between photos even before the model
        // wrappers exist. See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
        // Section 5 "Memory budget".

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
```

**Note:** the `databaseName` parameter above doesn't exist in Phase 0 until Task 6. Until Task 6 lands, leave the existing `ReportDatabase(folderPath: folder)` unchanged. Task 6 will edit this line. The memory-budget comment is what this task adds; the `name:` argument is a Task 6 concern.

So for Task 4 specifically, add only the memory-budget comment block at the shown insertion point, and leave the `ReportDatabase(folderPath: folder)` line as-is.

- [ ] **Step 4.3: Add `Task.yield()` at end of loop iteration**

Find the end of the `for fileURL in files { ... }` body (after `await onPhotoProcessed?()`):

```swift
            await onPhotoProcessed?()
        }
```

Replace with:

```swift
            await onPhotoProcessed?()

            // Yield once per iteration so ARC can release any temporaries
            // allocated by processOnePhoto before the next photo starts.
            // See memory-budget note above.
            await Task.yield()
        }
```

- [ ] **Step 4.4: Run `swift build`**

```bash
cd apps/mac-client && swift build
```

Expected: `Build complete!`.

- [ ] **Step 4.5: Run existing pipeline tests to verify no regression**

```bash
cd apps/mac-client && swift test --filter PipelineCoordinatorTests
```

Expected: all existing pipeline tests pass. `Task.yield()` is a no-op from a semantic standpoint — adding it between iterations is safe and doesn't affect the order photos are processed.

- [ ] **Step 4.6: Run the full test suite**

```bash
cd apps/mac-client && swift test
```

Expected: all tests pass including BDD and data tests. Photo count, processing order, rating outputs all unchanged.

- [ ] **Step 4.7: Commit**

```bash
git add apps/mac-client/SuperPickyApp/PipelineCoordinator.swift
git commit -m "feat(pipeline): yield between photos for ARC release prophylactic

Lightweight per-iteration Task.yield() so ARC gets a scheduled release
point between photos. The real fix — synchronous autoreleasepool{}
blocks around MLModel.prediction() calls — lands in Phase 2 model
wrappers where the sync scope actually works. This commit just lands
the scaffolding + documentation handoff. No behavior change in Phase 0.

See spec Section 5 Memory budget."
```

---

## Task 5: Add InferenceBackendSetting to Settings UI + localization

Adds an enum + a `CullingConfig` property + an `AdvancedTab` UI section + new entries in both Localizable.strings files. Phase 0 shows only the `.http` option; a caption note says native is coming in a future release. Phase 1 adds the `.native` option to the Picker.

**Files:**
- Create: `apps/mac-client/SuperPickyApp/InferenceBackendSetting.swift`
- Modify: `apps/mac-client/SuperPickyApp/CullingConfig.swift:49-91`
- Modify: `apps/mac-client/SuperPickyApp/AdvancedTab.swift:35-41`
- Modify: `apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings`
- Modify: `apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings`
- Create: `apps/mac-client/SuperPickyTests/Core/InferenceBackendSettingTests.swift`

### Steps

- [ ] **Step 5.1: Write the failing test**

Create `apps/mac-client/SuperPickyTests/Core/InferenceBackendSettingTests.swift`:

```swift
import Foundation
import Testing
@testable import SuperPicky

@Suite("InferenceBackendSetting")
struct InferenceBackendSettingTests {
    @Test("Enum has http and native cases")
    func cases() {
        #expect(InferenceBackend.allCases.count == 2)
        #expect(InferenceBackend.allCases.contains(.http))
        #expect(InferenceBackend.allCases.contains(.native))
    }

    @Test("Raw values are stable strings")
    func rawValues() {
        #expect(InferenceBackend.http.rawValue == "http")
        #expect(InferenceBackend.native.rawValue == "native")
    }

    @Test("CullingConfig defaults inferenceBackend to .http")
    func defaultsToHttp() {
        // Clear any persisted value first
        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
        let config = CullingConfig()
        #expect(config.inferenceBackend == .http)
    }

    @Test("CullingConfig.inferenceBackend persists to UserDefaults")
    func persistence() {
        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
        let config = CullingConfig()
        config.inferenceBackend = .native
        #expect(UserDefaults.standard.string(forKey: "inferenceBackend") == "native")

        // New instance reads persisted value
        let config2 = CullingConfig()
        #expect(config2.inferenceBackend == .native)

        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
    }
}
```

- [ ] **Step 5.2: Run the test — expected to fail with missing type**

```bash
cd apps/mac-client && swift test --filter InferenceBackendSettingTests
```

Expected: build failure — `cannot find 'InferenceBackend' in scope`.

- [ ] **Step 5.3: Create `InferenceBackendSetting.swift`**

Create `apps/mac-client/SuperPickyApp/InferenceBackendSetting.swift`:

```swift
// InferenceBackendSetting.swift
//
// User preference for which InferenceClient implementation to use.
// Phase 0: only .http is selectable in the UI. Phase 1+ enables .native
// once CoreMLInferenceClient exists and ModelManager reports .ready.

import Foundation

public enum InferenceBackend: String, CaseIterable, Codable, Sendable {
    case http
    case native

    public var displayNameKey: String {
        switch self {
        case .http: return "HTTP (Python server)"
        case .native: return "Native Core ML"
        }
    }
}
```

- [ ] **Step 5.4: Add `inferenceBackend` property to CullingConfig**

Edit `apps/mac-client/SuperPickyApp/CullingConfig.swift`. Find the stored-property declarations (lines 51–61) and add a new line before `init()`:

```swift
    var sharpnessThreshold: Float { didSet { save() } }
    var aestheticsThreshold: Float { didSet { save() } }
    var eyeSharpnessThreshold: Float { didSet { save() } }
    var exposureDetectionEnabled: Bool { didSet { save() } }
    var exposureThreshold: Float { didSet { save() } }
    var burstDetectionEnabled: Bool { didSet { save() } }
    var namingStandard: NamingStandard { didSet { save() } }
    var backendPort: Int { didSet { save() } }
    var autoAdvance: Bool { didSet { save() } }
    var appLanguage: AppLanguage { didSet { save() } }
    var appTheme: AppTheme { didSet { save() } }
    var inferenceBackend: InferenceBackend { didSet { save() } }
```

In `init()` (line 63), after `self.appTheme = ...` (line 75), add:

```swift
        self.inferenceBackend = InferenceBackend(rawValue: defaults.string(forKey: "inferenceBackend") ?? "") ?? .http
```

In `save()` (line 78), after `defaults.set(appTheme.rawValue, forKey: "appTheme")` (line 90), add:

```swift
        defaults.set(inferenceBackend.rawValue, forKey: "inferenceBackend")
```

- [ ] **Step 5.5: Run the test — should pass**

```bash
cd apps/mac-client && swift test --filter InferenceBackendSettingTests
```

Expected: 4 tests passing.

- [ ] **Step 5.6: Add localized strings — English**

Append to `apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings`:

```
"Inference Backend" = "Inference Backend";
"HTTP (Python server)" = "HTTP (Python server)";
"Native Core ML" = "Native Core ML";
"Native Core ML backend will be available in a future release." = "Native Core ML backend will be available in a future release.";
```

- [ ] **Step 5.7: Add localized strings — Chinese (zh-Hans)**

Append to `apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings`:

```
"Inference Backend" = "推理后端";
"HTTP (Python server)" = "HTTP (Python 服务器)";
"Native Core ML" = "原生 Core ML";
"Native Core ML backend will be available in a future release." = "原生 Core ML 后端将在未来版本中提供。";
```

- [ ] **Step 5.8: Update `AdvancedTab` with new Section**

Edit `apps/mac-client/SuperPickyApp/AdvancedTab.swift`. Replace the existing `Section("Backend")` block (lines 35–41) with:

```swift
            Section(config.localized("Backend")) {
                HStack {
                    Text(config.localized("Python server port"))
                    TextField("Port", value: $config.backendPort, format: .number)
                        .frame(width: 80)
                }
            }
            Section(config.localized("Inference Backend")) {
                Picker(config.localized("Inference Backend"), selection: $config.inferenceBackend) {
                    Text(config.localized("HTTP (Python server)")).tag(InferenceBackend.http)
                    // Phase 1 adds:
                    // Text(config.localized("Native Core ML")).tag(InferenceBackend.native)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Text(config.localized("Native Core ML backend will be available in a future release."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

**Note:** `Section("Backend")` now needs to be localized too if it wasn't already. If `config.localized("Backend")` already returns "Backend" (which it will because `"Backend" = "Backend";` is in line 11 of en.lproj per the earlier Read), this works. No new string needed for "Backend" itself; the en file already has it.

Also add `"Python server port"` if missing. Check with:

```bash
grep -n "Python server port" apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings
```

If no match, add to both `.strings` files:

```
"Python server port" = "Python server port";          # en
"Python server port" = "Python 服务器端口";            # zh-Hans
```

- [ ] **Step 5.9: Run `swift build`**

```bash
cd apps/mac-client && swift build
```

Expected: `Build complete!`. If SwiftUI complains that `InferenceBackend` needs to be `Hashable` for `.tag(...)`, add `Hashable` conformance (it's already implied by `Codable + CaseIterable` for simple enums, but explicit is fine):

```swift
public enum InferenceBackend: String, CaseIterable, Codable, Hashable, Sendable {
```

- [ ] **Step 5.10: Launch the app manually and verify the Settings → Advanced tab shows the new section**

```bash
cd apps/mac-client && xcodegen && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -5 && open ./build/Debug/SuperPicky.app 2>/dev/null || true
```

Expected: app launches. Open Settings (Cmd+,) → Advanced tab → "Inference Backend" section shows a Picker with "HTTP (Python server)" selected, caption below reading "Native Core ML backend will be available in a future release." Change language to Chinese in the General tab — the new strings should display in Chinese.

(If the open command doesn't find the `.app` because xcodebuild put it in DerivedData, open Xcode manually instead.)

- [ ] **Step 5.11: Commit**

```bash
git add apps/mac-client/SuperPickyApp/InferenceBackendSetting.swift \
        apps/mac-client/SuperPickyApp/CullingConfig.swift \
        apps/mac-client/SuperPickyApp/AdvancedTab.swift \
        apps/mac-client/SuperPickyApp/en.lproj/Localizable.strings \
        apps/mac-client/SuperPickyApp/zh-Hans.lproj/Localizable.strings \
        apps/mac-client/SuperPickyTests/Core/InferenceBackendSettingTests.swift
git commit -m "feat(ui): add InferenceBackend setting in Advanced tab

Settings toggle for inference backend. Phase 0 shows only HTTP; caption
notes native will come later. Phase 1 will add the .native option to
the Picker once CoreMLInferenceClient exists. New strings localized
in both en and zh-Hans."
```

---

## Task 6: Parity test target shell + databaseName parameter

Creates the empty `SuperPickyTests/Parity/` directory with an empty `ParityTestBase.swift` for later phases to extend. Also adds the optional `databaseName: String = ".report.db"` parameter to `PipelineCoordinator.process(...)` and `ReportDatabase.init(...)` — Phase 4b needs this to run the rating parity test against two side-by-side `.report-*.db` files in the same folder.

**Files:**
- Create: `apps/mac-client/SuperPickyTests/Parity/ParityTestBase.swift`
- Modify: `apps/mac-client/SuperPickyApp/PipelineCoordinator.swift` (add param)
- Modify: `apps/mac-client/SuperPickyApp/ReportDatabase.swift` (add param)
- Create: `apps/mac-client/SuperPickyTests/Core/PipelineCoordinatorDatabaseNameTests.swift`

### Steps

- [ ] **Step 6.1: Read the current `ReportDatabase.init` signature to know exactly what to change**

```bash
grep -n "init" apps/mac-client/SuperPickyApp/ReportDatabase.swift | head -5
```

Expected output: one or more lines showing the init signature. Note the exact signature — you'll need it in Step 6.4.

- [ ] **Step 6.2: Write the failing test for databaseName parameter**

Create `apps/mac-client/SuperPickyTests/Core/PipelineCoordinatorDatabaseNameTests.swift`:

```swift
import Foundation
import Testing
@testable import SuperPicky

@Suite("PipelineCoordinator databaseName parameter")
struct PipelineCoordinatorDatabaseNameTests {
    @Test("ReportDatabase.init(folderPath:) defaults name to .report.db")
    func defaultDatabaseName() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir)
        let expectedURL = tmpDir.appendingPathComponent(".report.db")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    @Test("ReportDatabase.init(folderPath:name:) uses the custom name")
    func customDatabaseName() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-custom.db")
        let customURL = tmpDir.appendingPathComponent(".report-custom.db")
        let defaultURL = tmpDir.appendingPathComponent(".report.db")
        #expect(FileManager.default.fileExists(atPath: customURL.path))
        #expect(!FileManager.default.fileExists(atPath: defaultURL.path))
    }

    @Test("Two databases can coexist in the same folder")
    func twoSideBySide() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-http.db")
        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-native.db")

        let httpURL = tmpDir.appendingPathComponent(".report-http.db")
        let nativeURL = tmpDir.appendingPathComponent(".report-native.db")
        #expect(FileManager.default.fileExists(atPath: httpURL.path))
        #expect(FileManager.default.fileExists(atPath: nativeURL.path))
    }
}
```

- [ ] **Step 6.3: Run the test — expected to fail because `name:` parameter doesn't exist yet**

```bash
cd apps/mac-client && swift test --filter PipelineCoordinatorDatabaseNameTests
```

Expected: compile error on `.init(folderPath: tmpDir, name: ...)` — no matching init.

- [ ] **Step 6.4: Add `name` parameter to `ReportDatabase.init`**

Read the current `ReportDatabase.swift` init to see exactly what's there.

```bash
sed -n '1,40p' apps/mac-client/SuperPickyApp/ReportDatabase.swift
```

Find the init that takes `folderPath: URL`. It will look something like:

```swift
init(folderPath: URL) throws {
    let dbURL = folderPath.appendingPathComponent(".report.db")
    // ... GRDB setup ...
}
```

Change it to:

```swift
init(folderPath: URL, name: String = ".report.db") throws {
    let dbURL = folderPath.appendingPathComponent(name)
    // ... rest unchanged ...
}
```

**Only change the signature and the one line that builds `dbURL`.** Every other line stays exactly the same.

- [ ] **Step 6.5: Thread `databaseName` through `PipelineCoordinator.process`**

Edit `apps/mac-client/SuperPickyApp/PipelineCoordinator.swift`. Find the `process(...)` method signature (starts around line 26). Add the new parameter just before the closing paren:

```swift
    func process(
        folder: URL,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
        burstDetectionEnabled: Bool = true,
        databaseName: String = ".report.db",
        onPhotoProcessed: (@Sendable () async -> Void)? = nil
    ) async {
```

Find the call to `ReportDatabase(folderPath: folder)` (around line 49) and change it to pass `name`:

```swift
        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
        } catch {
            logger.error("Failed to open database: \(error)")
            return
        }
```

- [ ] **Step 6.6: Run the test — should pass**

```bash
cd apps/mac-client && swift test --filter PipelineCoordinatorDatabaseNameTests
```

Expected: 3 tests passing.

- [ ] **Step 6.7: Run the full test suite to verify no regression from the signature change**

```bash
cd apps/mac-client && swift test
```

Expected: all tests pass. Existing calls to `ReportDatabase(folderPath:)` still work because the new `name:` parameter has a default value. Existing calls to `PipelineCoordinator.process(...)` still work for the same reason.

- [ ] **Step 6.8: Create the Parity test target directory**

```bash
mkdir -p apps/mac-client/SuperPickyTests/Parity
```

- [ ] **Step 6.9: Create `ParityTestBase.swift`**

Create `apps/mac-client/SuperPickyTests/Parity/ParityTestBase.swift`:

```swift
// ParityTestBase.swift
//
// Base class for Gate #1 (per-endpoint parity) and Gate #2 (end-to-end
// rating diff) parity tests. Phase 0 ships this as an empty shell;
// Phase 1+ adds real setUp() that boots both HTTPInferenceClient and
// CoreMLInferenceClient against a pre-staged model cache.
//
// See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
// Section 6 "Parity testing".

import XCTest
@testable import SuperPicky
@testable import SuperPickyInference

/// Base class for all parity tests. No active test methods in Phase 0.
///
/// Phase 1+ implementers: add setUp() that creates:
///   - httpClient: HTTPInferenceClient (against L2 Python server on 18420)
///   - nativeClient: CoreMLInferenceClient (with pre-staged model cache)
///   - fixtureDir: URL pointing at test Parity/Fixtures/
@MainActor
class ParityTestBase: XCTestCase {
    /// Intentionally empty in Phase 0. Keeps the Parity target compiling
    /// so Phase 1 can add its first test without structural changes.
    func test_parityHarnessCompiles() throws {
        // Sentinel test — no assertions. Exists so XCTest doesn't report
        // "no tests ran" which some CI configurations treat as a failure.
        XCTAssertTrue(true, "Parity harness placeholder; real tests start in Phase 1")
    }
}
```

- [ ] **Step 6.10: Verify the Parity test target compiles and the sentinel runs**

```bash
cd apps/mac-client && swift test --filter ParityTestBase
```

Expected: 1 test passing (`test_parityHarnessCompiles`). If `swift test --filter` doesn't find it, the test runner's filter syntax may differ — run the full suite and confirm the new file appears:

```bash
cd apps/mac-client && swift test 2>&1 | grep -i parity
```

- [ ] **Step 6.11: Run full test suite and xcodebuild**

```bash
cd apps/mac-client && swift test && xcodegen && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -10
```

Expected: `Test Suite ... passed` and `** BUILD SUCCEEDED **`.

- [ ] **Step 6.12: Commit**

```bash
git add apps/mac-client/SuperPickyApp/ReportDatabase.swift \
        apps/mac-client/SuperPickyApp/PipelineCoordinator.swift \
        apps/mac-client/SuperPickyTests/Core/PipelineCoordinatorDatabaseNameTests.swift \
        apps/mac-client/SuperPickyTests/Parity/ParityTestBase.swift
git commit -m "chore(tests): add Parity target shell + databaseName parameter

ParityTestBase sentinel keeps XCTest happy with zero real tests. Phase
1+ adds per-endpoint (Gate #1) and rating-diff (Gate #2) tests here.

PipelineCoordinator.process gains an optional databaseName parameter
(defaults to .report.db) so Phase 4b can run both HTTP and native
backends against the same folder into .report-http.db and
.report-native.db side-by-side. ReportDatabase.init accepts the name
too; existing callers unchanged."
```

---

## Phase 0 Completion Check

After all six tasks, run:

```bash
cd apps/mac-client && swift build && swift test && xcodegen && xcodebuild -project SuperPicky.xcodeproj -scheme SuperPicky -configuration Debug build 2>&1 | tail -5
```

Expected:
- `Build complete!` (SPM build)
- `Test Suite 'All tests' passed` (SPM tests — existing + 4 new unit tests + 4 manifest + 4 manager + 4 backend setting + 3 databaseName + 1 parity sentinel = **20+ new passing tests**)
- `** BUILD SUCCEEDED **` (xcodebuild)

Then verify the git log:

```bash
git log --oneline -7
```

Expected: 6 new commits on top of the current HEAD (plus the existing HEAD). Commit messages:

```
chore(tests): add Parity target shell + databaseName parameter
feat(ui): add InferenceBackend setting in Advanced tab
feat(pipeline): cycle ARC releases between photos in processing loop
feat(manager): add ModelManager actor with ensureReady() empty-manifest fast path
feat(manifest): add ModelManifest type + bundled stub manifest.json
feat(spm): add SuperPickyInference target with InferenceConstants
```

Plus the pre-existing `docs: add native-inference-rewrite design` (`579c29f`).

---

## After Phase 0 Merges

The next plan (`2026-04-15-native-inference-phase-1.md`) will cover Phase 1 (Flight model, EfficientNet-B3 → Core ML → `FlightModel.swift` → `CoreMLInferenceClient.flight()` → first native endpoint). It depends on:

- The `SuperPickyInference` target existing (Task 1)
- `ModelManifest` being available to add flight entries to (Task 2)
- `ModelManager.ensureReady()` to be extendable (Task 3)
- `InferenceBackend.native` already being an enum case the Picker can add (Task 5)
- The Parity test scaffolding to extend (Task 6)

None of those dependencies require Phase 0 commits to be split; they just need Phase 0 to be merged before Phase 1 starts.

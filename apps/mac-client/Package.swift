// swift-tools-version: 5.10
import PackageDescription

let warningsAsErrors: [SwiftSetting] = [.unsafeFlags(["-warnings-as-errors"])]

let package = Package(
    name: "SuperPicky",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "SuperPickyInference",
            path: "SuperPickyInference",
            exclude: [
                // .mlpackage directories are converter source artifacts that
                // may exist locally; they are never shipped.
                "Resources/Models/FlightDetector.mlpackage",
                "Resources/Models/KeypointDetector.mlpackage",
                "Resources/Models/YOLOBirdDetector.mlpackage",
                "Resources/Models/OSEAClassifier.mlpackage",
                "Resources/Models/AestheticsModel.mlpackage",
            ],
            resources: [
                // manifest.json lists the weight.bin files to download on
                // first launch along with SHA-256 for verification.
                .process("Resources/manifest.json"),
                // bird_reference.sqlite is small and always needed, so it
                // ships bundled rather than via the download manager.
                .copy("Resources/bird_reference.sqlite"),
                // CoreML model scaffolds (~1 MB total) ship in the bundle;
                // only the weights/weight.bin file inside each is missing
                // and gets fetched by ModelManager on first launch.
                .copy("Resources/Models/FlightDetector.mlmodelc"),
                .copy("Resources/Models/KeypointDetector.mlmodelc"),
                .copy("Resources/Models/YOLOBirdDetector.mlmodelc"),
                .copy("Resources/Models/OSEAClassifier.mlmodelc"),
                .copy("Resources/Models/AestheticsModel.mlmodelc"),
                // Offline eBird country/region species lists (~1.8 MB)
                // used by SpeciesFilter for GPS-based OSEA candidate filtering.
                .copy("Resources/ebird"),
            ],
            swiftSettings: warningsAsErrors
        ),
        .executableTarget(
            name: "SuperPicky",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SuperPickyInference",
            ],
            path: "SuperPickyApp",
            exclude: ["en.lproj", "zh-Hans.lproj"],
            swiftSettings: warningsAsErrors
        ),
        .testTarget(
            name: "SuperPickyTests",
            dependencies: [
                "SuperPicky",
                "SuperPickyInference",
            ],
            path: "SuperPickyTests",
            swiftSettings: warningsAsErrors
        ),
    ]
)

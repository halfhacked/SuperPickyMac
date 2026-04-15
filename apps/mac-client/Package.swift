// swift-tools-version: 5.10
import PackageDescription

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
                // Models/ is not bundled — downloaded on first launch via ModelManager
                // into ~/Library/Application Support/…/ModelCache/
                "Resources/Models",
            ],
            resources: [
                // manifest.json lists downloadable CoreML models with SHA-256;
                // ModelManager fetches them on first launch.
                .process("Resources/manifest.json"),
                // bird_reference.sqlite is small (~9 MB zipped) and always needed,
                // so it ships bundled rather than via the download manager.
                .copy("Resources/bird_reference.sqlite"),
            ]
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
)

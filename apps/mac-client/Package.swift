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
)

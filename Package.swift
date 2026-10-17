// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexUsageStatus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageStatus", targets: ["CodexUsageStatus"]),
        .library(name: "CodexUsageStatusCore", targets: ["CodexUsageStatusCore"])
    ],
    targets: [
        .target(
            name: "CodexUsageStatusCore",
            path: "Sources/CodexUsageStatus",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "CodexUsageStatus",
            dependencies: ["CodexUsageStatusCore"],
            path: "Sources/CodexUsageStatusLauncher",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

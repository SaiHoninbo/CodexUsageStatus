// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexUsageStatus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageStatus", targets: ["CodexUsageStatus"])
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageStatus",
            path: "Sources/CodexUsageStatus",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

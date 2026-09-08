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
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.6")
    ],
    targets: [
        .executableTarget(
            name: "CodexUsageStatus",
            dependencies: [
                .product(name: "Sparkle", package: "sparkle")
            ],
            path: "Sources/CodexUsageStatus",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)

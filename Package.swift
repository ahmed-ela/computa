// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LocalCodex",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalCodex", targets: ["LocalCodex"])
    ],
    targets: [
        .target(
            name: "AutomationCore",
            path: "Sources/AutomationCore"
        ),
        .executableTarget(
            name: "LocalCodex",
            dependencies: ["AutomationCore"],
            path: "Sources/LocalCodex",
            resources: [
                .copy("Resources/WebUI")
            ]
        ),
        .testTarget(
            name: "AutomationCoreTests",
            dependencies: ["AutomationCore"],
            path: "Tests/AutomationCoreTests"
        ),
        .testTarget(
            name: "LocalCodexTests",
            dependencies: ["LocalCodex"],
            path: "Tests/LocalCodexTests"
        )
    ]
)

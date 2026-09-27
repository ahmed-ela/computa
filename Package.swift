// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Mactopus",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Mactopus", targets: ["Mactopus"])
    ],
    targets: [
        .target(
            name: "AutomationCore",
            path: "Sources/AutomationCore"
        ),
        .executableTarget(
            name: "Mactopus",
            dependencies: ["AutomationCore"],
            path: "Sources/Mactopus",
            resources: [
                .copy("Resources/WebUI"),
                .copy("Resources/VisualGrounding"),
                .copy("Resources/AgentRuntime"),
                .copy("Resources/MLXServer"),
                .copy("Resources/AgentInstructions")
            ]
        ),
        .testTarget(
            name: "AutomationCoreTests",
            dependencies: ["AutomationCore"],
            path: "Tests/AutomationCoreTests"
        ),
        .testTarget(
            name: "MactopusTests",
            dependencies: ["Mactopus"],
            path: "Tests/MactopusTests"
        )
    ]
)

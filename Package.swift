// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Macrouse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Macrouse", targets: ["Macrouse"])
    ],
    targets: [
        .target(
            name: "AutomationCore",
            path: "Sources/AutomationCore"
        ),
        .executableTarget(
            name: "Macrouse",
            dependencies: ["AutomationCore"],
            path: "Sources/Macrouse",
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
            name: "MacrouseTests",
            dependencies: ["Macrouse"],
            path: "Tests/MacrouseTests"
        )
    ]
)

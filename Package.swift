// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Computa",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Computa", targets: ["Computa"])
    ],
    targets: [
        .target(
            name: "AutomationCore",
            path: "Sources/AutomationCore"
        ),
        .executableTarget(
            name: "Computa",
            dependencies: ["AutomationCore"],
            path: "Sources/Computa",
            resources: [
                .copy("Resources/WebUI"),
                .copy("Resources/VisualGrounding"),
                .copy("Resources/AgentRuntime"),
                .copy("Resources/MLXServer"),
                .copy("Resources/BrowserModels")
            ]
        ),
        .testTarget(
            name: "AutomationCoreTests",
            dependencies: ["AutomationCore"],
            path: "Tests/AutomationCoreTests"
        ),
        .testTarget(
            name: "ComputaTests",
            dependencies: ["Computa"],
            path: "Tests/ComputaTests"
        )
    ]
)

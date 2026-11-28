// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Kolmogor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Kolmogor", targets: ["Computa"])
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
                .copy("Assets.xcassets/BrowserGlobe.imageset/BrowserGlobe.svg"),
                .copy("Resources/WebUI"),
                .copy("Resources/VisualGrounding"),
                .copy("Resources/AgentRuntime"),
                .copy("Resources/MLXServer"),
                .copy("Resources/BrowserModels"),
                .copy("Resources/ProviderSetup"),
                .copy("Resources/CodexDesktop"),
                .copy("Resources/BrowserToolCatalog.json"),
                .copy("Resources/Tokenizers")
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

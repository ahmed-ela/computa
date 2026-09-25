// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HeyDash",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "HeyDash", targets: ["HeyDash"])
    ],
    targets: [
        .target(
            name: "AutomationCore",
            path: "Sources/AutomationCore"
        ),
        .executableTarget(
            name: "HeyDash",
            dependencies: ["AutomationCore"],
            path: "Sources/HeyDash",
            resources: [
                .copy("Resources/WebUI"),
                .copy("Resources/VisualGrounding"),
                .copy("Resources/AgentRuntime")
            ]
        ),
        .testTarget(
            name: "AutomationCoreTests",
            dependencies: ["AutomationCore"],
            path: "Tests/AutomationCoreTests"
        ),
        .testTarget(
            name: "HeyDashTests",
            dependencies: ["HeyDash"],
            path: "Tests/HeyDashTests"
        )
    ]
)

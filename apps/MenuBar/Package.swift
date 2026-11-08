// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClaudeCodexBridge",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .executable(name: "bridge", targets: ["BridgeCLI"]),
        .executable(
            name: "ClaudeCodexBridgeMenuBar",
            targets: ["ClaudeCodexBridgeMenuBar"]
        ),
    ],
    dependencies: [
        .package(path: "../../packages/WorkspaceContracts"),
    ],
    targets: [
        .target(
            name: "BridgeCore",
            dependencies: [.product(name: "WorkspaceContracts", package: "WorkspaceContracts")],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("LocalAuthentication"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "BridgeCLI",
            dependencies: ["BridgeCore"]
        ),
        .executableTarget(
            name: "ClaudeCodexBridgeMenuBar",
            dependencies: ["BridgeCore"],
            resources: [.copy("Resources/ProviderLogos"), .copy("Resources/AgentPersonas"), .copy("Resources/Brand"), .copy("Resources/SkillPortraits")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
        .testTarget(
            name: "BridgeCoreTests",
            dependencies: ["BridgeCore", .product(name: "WorkspaceContracts", package: "WorkspaceContracts")]
        ),
        .testTarget(
            name: "BridgeUITests",
            dependencies: ["BridgeCore", "ClaudeCodexBridgeMenuBar"]
        ),
    ]
)

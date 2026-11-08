// swift-tools-version: 5.9

import PackageDescription

// Portable wire types for receipts, outcomes, effort assessments and economic
// reports. Foundation only: no AppKit, provider launchers, credentials or
// databases, so other tools (and other platforms) can read the same files.
let package = Package(
    name: "WorkspaceContracts",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WorkspaceContracts", targets: ["WorkspaceContracts"]),
    ],
    targets: [
        .target(name: "WorkspaceContracts"),
        .testTarget(name: "WorkspaceContractsTests", dependencies: ["WorkspaceContracts"]),
    ]
)

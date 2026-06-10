// swift-tools-version: 5.9

import Foundation
import PackageDescription

let strictConcurrency: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]

let siblingOpenNookManifest = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../opennook/Package.swift")

let opennookDependency: Package.Dependency =
    FileManager.default.fileExists(atPath: siblingOpenNookManifest.path)
    ? .package(path: "../opennook")
    : .package(url: "https://github.com/glendonC/opennook.git", from: "0.2.0")

let package = Package(
    name: "Peeknook",
    defaultLocalization: "en",
    platforms: [
        .macOS("15.0")
    ],
    products: [
        .executable(name: "Peeknook", targets: ["PeeknookExecutable"]),
        .library(name: "PeeknookHost", targets: ["PeeknookHost"]),
        .library(name: "PeeknookCore", targets: ["PeeknookCore"]),
        .library(name: "PeeknookUI", targets: ["PeeknookUI"]),
        .library(name: "PeeknookDesign", targets: ["PeeknookDesign"])
    ],
    dependencies: [
        opennookDependency
    ],
    targets: [
        .target(
            name: "PeeknookCore",
            path: "Sources/PeeknookCore",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PeeknookDesign",
            dependencies: [
                .product(name: "NookApp", package: "opennook")
            ],
            path: "Sources/PeeknookDesign",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PeeknookUI",
            dependencies: [
                "PeeknookCore",
                "PeeknookDesign"
            ],
            path: "Sources/PeeknookUI",
            resources: [.process("Resources")],
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PeeknookHost",
            dependencies: [
                "PeeknookCore",
                "PeeknookUI",
                .product(name: "NookApp", package: "opennook")
            ],
            path: "Sources/PeeknookHost",
            swiftSettings: strictConcurrency
        ),
        .executableTarget(
            name: "PeeknookExecutable",
            dependencies: ["PeeknookHost"],
            path: "Sources/PeeknookExecutable",
            swiftSettings: strictConcurrency
        ),
        .testTarget(
            name: "PeeknookCoreTests",
            dependencies: ["PeeknookCore"],
            path: "Tests/PeeknookCoreTests",
            swiftSettings: strictConcurrency
        ),
        // Pure UI-layer logic (layout math, internal helpers) — no rendering, no XCUITest.
        .testTarget(
            name: "PeeknookUILogicTests",
            dependencies: ["PeeknookUI"],
            path: "Tests/PeeknookUILogicTests",
            swiftSettings: strictConcurrency
        )
    ]
)

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
    : .package(url: "https://github.com/athledev-labs/opennook.git", from: "0.4.0")

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
        opennookDependency,
        // On-device Whisper (Argmax) for the live-caption ASR engine. Used ONLY by the isolated
        // `PeeknookWhisper` target so PeeknookCore (and its fast test suite) never links the heavy
        // Core ML model stack. Models download at runtime from HuggingFace on first use, not at resolve.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
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
        // Isolated home for the heavy on-device Whisper engine. Depends on PeeknookCore for the
        // `StreamingTranscribing` seam and on WhisperKit for the Core ML ASR; nothing in Core or its tests
        // links it. The host wires the Whisper-backed transcriber in through the existing seam.
        .target(
            name: "PeeknookWhisper",
            dependencies: [
                "PeeknookCore",
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Sources/PeeknookWhisper",
            swiftSettings: strictConcurrency
        ),
        .target(
            name: "PeeknookHost",
            dependencies: [
                "PeeknookCore",
                "PeeknookUI",
                "PeeknookWhisper",
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

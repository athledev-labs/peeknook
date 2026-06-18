// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Slice 1 of the user-extensible tool-ground platform: the `.tool` ground + the `ToolSpec` schema.
/// Pure schema — no provider runs a tool yet. These guard the tolerant decode, the text-only modality,
/// the profile persistence round-trip, and the security rule that a `.command` tool never survives a
/// shared preset (the untrusted import boundary).
final class ToolSpecTests: XCTestCase {

    // MARK: - The .tool ground

    func testToolGroundStableRawValueAndIsTextOnly() {
        XCTAssertEqual(Ground.tool.rawValue, "tool")
        XCTAssertEqual(Ground(rawValue: "tool"), .tool)
        XCTAssertTrue(Ground.allCases.contains(.tool))
        // A tool contributes a TEXT leg, never an image.
        XCTAssertTrue(Ground.textOnlyLegs.contains(.tool))
        XCTAssertEqual(MediaPayload.Kind.resolved(for: .tool), .transcript)
    }

    func testToolGroundIsPrimaryOnlyAndNeedsNoPermission() {
        // v1: a tool is a profile's PRIMARY ground, not a supplementary fan-out leg.
        XCTAssertFalse(Ground.multiGroundEligible.contains(.tool))
        // A loopback tool needs no TCC of its own (a screenshot-input tool's Screen Recording composes
        // at the profile-readiness level in slice 2, not on the ground here).
        XCTAssertTrue(Ground.tool.requiredPermissions.isEmpty)
    }

    // MARK: - ToolSpec tolerant decode

    private func decode(_ json: String) -> ToolSpec? {
        try? JSONDecoder().decode(ToolSpec.self, from: Data(json.utf8))
    }

    func testUnknownTransportFallsBackToSafeHTTP() {
        let spec = decode(#"{"transport":"telepathy","url":"http://127.0.0.1:7000"}"#)
        XCTAssertEqual(spec?.transport, .http, "an unknown transport degrades to the safe loopback HTTP, never .command")
        XCTAssertEqual(spec?.url, "http://127.0.0.1:7000")
        XCTAssertTrue(spec?.isUsable ?? false)
    }

    func testMissingFieldsTakeSafeDefaults() {
        let spec = decode("{}")
        XCTAssertEqual(spec?.transport, .http)
        XCTAssertNil(spec?.url)
        XCTAssertNil(spec?.command)
        XCTAssertEqual(spec?.isUsable, false, "no endpoint ⇒ unusable ⇒ the profile degrades to no tool")
        XCTAssertEqual(spec?.sendsScreenshot, true)
        XCTAssertEqual(spec?.sendsText, false)
        XCTAssertEqual(spec?.outputLabel, ToolSpec.defaultOutputLabel)
        XCTAssertEqual(spec?.timeoutSeconds, ToolSpec.defaultTimeoutSeconds)
    }

    func testEmptyEndpointNormalizesToNil() {
        let spec = decode(#"{"transport":"command","command":"   "}"#)
        XCTAssertEqual(spec?.transport, .command)
        XCTAssertNil(spec?.command, "a whitespace-only endpoint is treated as none")
        XCTAssertEqual(spec?.isUsable, false)
    }

    func testTimeoutClampedAndLabelCapped() {
        let big = decode(#"{"transport":"http","url":"http://127.0.0.1:1","timeoutSeconds":9999}"#)
        XCTAssertEqual(big?.timeoutSeconds, ToolSpec.maxTimeoutSeconds)
        let small = decode(#"{"transport":"http","url":"http://127.0.0.1:1","timeoutSeconds":-5}"#)
        XCTAssertEqual(small?.timeoutSeconds, ToolSpec.minTimeoutSeconds)
        let spec = ToolSpec(transport: .http, url: "http://127.0.0.1:1", outputLabel: String(repeating: "x", count: 500))
        XCTAssertEqual(spec.outputLabel.count, ToolSpec.maxOutputLabelLength, "a paste-bomb label is capped")
    }

    func testToolSpecRoundTrips() throws {
        let spec = ToolSpec(
            transport: .http, url: "http://127.0.0.1:7000", arguments: ["--depth", "20"],
            sendsScreenshot: true, sendsText: true, outputLabel: "Engine analysis", timeoutSeconds: 12
        )
        let decoded = try JSONDecoder().decode(ToolSpec.self, from: JSONEncoder().encode(spec))
        XCTAssertEqual(decoded, spec)
    }

    // MARK: - GroundProfile carries the tool through persistence

    func testGroundProfileWithToolSpecRoundTrips() throws {
        let profile = GroundProfile(
            id: "u1", displayNameKey: "Chess", symbol: "checkerboard.rectangle",
            primaryGround: .tool, activeGrounds: [.tool], isBuiltIn: false,
            displayName: "Chess", instruction: "Explain the engine's best move; never invent one.",
            toolSpec: ToolSpec(transport: .http, url: "http://127.0.0.1:7000", outputLabel: "Engine")
        )
        let decoded = try JSONDecoder().decode(GroundProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.toolSpec, profile.toolSpec)
        XCTAssertEqual(decoded.primaryGround, .tool)
    }

    func testNonToolProfileOmitsTheToolKey() throws {
        // A profile with no tool stays byte-identical to before — the new key is conditional.
        let json = String(decoding: try JSONEncoder().encode(GroundProfile.screenDefault), as: UTF8.self)
        XCTAssertFalse(json.contains("toolSpec"), "the toolSpec key is omitted when nil")
    }

    // MARK: - Preset sharing: a .command tool never crosses the untrusted import boundary

    private func chessProfile(_ tool: ToolSpec) -> GroundProfile {
        GroundProfile(
            id: "u1", displayNameKey: "Chess", symbol: "checkerboard.rectangle",
            primaryGround: .tool, activeGrounds: [.tool], isBuiltIn: false,
            displayName: "Chess", instruction: "Explain the move.", toolSpec: tool
        )
    }

    func testSharedPresetStripsCommandToolButKeepsTheProfile() {
        let installed = ProfilePreset(profiles: [chessProfile(ToolSpec(transport: .command, command: "/opt/peeknook-stockfish"))])
            .installable(into: .empty)
        XCTAssertEqual(installed.count, 1)
        XCTAssertNil(installed.first?.toolSpec, "an executable .command tool is stripped on import")
        XCTAssertEqual(installed.first?.instruction, "Explain the move.", "the prompt/instruction still imports")
        XCTAssertEqual(installed.first?.primaryGround, .tool)
    }

    func testSharedPresetKeepsLoopbackHTTPTool() {
        let installed = ProfilePreset(profiles: [chessProfile(ToolSpec(transport: .http, url: "http://127.0.0.1:7000", outputLabel: "Engine"))])
            .installable(into: .empty)
        XCTAssertEqual(installed.first?.toolSpec?.transport, .http, "a loopback HTTP tool travels intact (no code)")
        XCTAssertEqual(installed.first?.toolSpec?.url, "http://127.0.0.1:7000")
    }

    func testCommandToolDoesNotSurviveExportThenInstall() throws {
        let data = try ProfilePreset.export([chessProfile(ToolSpec(transport: .command, command: "/opt/x"))])
        let installed = try JSONDecoder().decode(ProfilePreset.self, from: data).installable(into: .empty)
        XCTAssertNil(installed.first?.toolSpec, "a command tool never survives the share → install round trip")
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class GroundProfileTests: XCTestCase {
    // MARK: Required-permission matrix

    func testScreenDefaultRequiresOnlyScreenRecording() {
        // AX (selectedText) is supplementary and must NOT appear — preserves the "Screen Recording
        // is the only capture gate" invariant while the matrix becomes profile-aware.
        XCTAssertEqual(GroundProfile.screenDefault.requiredPermissions, [.screenRecording])
    }

    func testGroundRequiredPermissions() {
        XCTAssertEqual(Ground.screen.requiredPermissions, [.screenRecording])
        XCTAssertEqual(Ground.camera.requiredPermissions, [.camera])
        XCTAssertEqual(Ground.voiceInput.requiredPermissions, [.microphone, .speechRecognition])
        XCTAssertEqual(Ground.selectedText.requiredPermissions, [])
        XCTAssertEqual(Ground.agent.requiredPermissions, [])
    }

    // MARK: Catalog resolution

    func testBuiltInFallsBackToScreenDefaultForUnknownID() {
        XCTAssertEqual(GroundProfile.builtIn(id: "screen.default"), .screenDefault)
        XCTAssertEqual(GroundProfile.builtIn(id: "does.not.exist"), .screenDefault)
    }

    // MARK: Tolerant Codable (the reset-bomb defuse)

    func testRoundTripPreservesScreenDefault() throws {
        let data = try JSONEncoder().encode(GroundProfile.screenDefault)
        let decoded = try JSONDecoder().decode(GroundProfile.self, from: data)
        XCTAssertEqual(decoded, .screenDefault)
    }

    func testUnknownGroundRawValuesAreDroppedNotThrown() throws {
        // A profile written by a newer build naming a future ground must decode (dropping the
        // unknown values), never throw and reset the catalog.
        let json = Data("""
        {
          "id": "future.profile",
          "displayNameKey": "Future",
          "symbol": "sparkles",
          "primaryGround": "warpDrive",
          "activeGrounds": ["screen", "futuristicScanner", "selectedText"],
          "isBuiltIn": false
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(GroundProfile.self, from: json)
        XCTAssertEqual(decoded.primaryGround, .screen, "Unknown primary ground falls back to .screen.")
        XCTAssertEqual(
            decoded.activeGrounds,
            [.screen, .selectedText],
            "Unknown active grounds are dropped; the primary ground is always present."
        )
    }

    func testMissingIsBuiltInDefaultsFalse() throws {
        let json = Data("""
        {"id":"x","displayNameKey":"X","symbol":"s","primaryGround":"screen","activeGrounds":["screen"]}
        """.utf8)
        let decoded = try JSONDecoder().decode(GroundProfile.self, from: json)
        XCTAssertFalse(decoded.isBuiltIn)
    }

    // MARK: Active-profile resolution

    func testActiveProfileIDDefaultsToScreenDefault() {
        XCTAssertEqual(PeeknookSettings().activeProfileID, "screen.default")
        XCTAssertEqual(GroundProfile.resolve(id: PeeknookSettings().activeProfileID, in: []), .screenDefault)
    }

    func testActiveProfileIDDecodesTolerantlyFromLegacyBlob() throws {
        // A settings blob written before the key existed defaults to screen.default (no reset).
        let legacy = Data(#"{"textModel":"gemma4:e4b"}"#.utf8)
        let decoded = try JSONDecoder().decode(PeeknookSettings.self, from: legacy)
        XCTAssertEqual(decoded.activeProfileID, "screen.default")
    }

    func testUnknownActiveProfileIDFallsBackToScreenDefault() {
        XCTAssertEqual(GroundProfile.resolve(id: "does.not.exist", in: []), .screenDefault)
    }

    func testCameraStudyResolvesFromTheCatalog() {
        XCTAssertEqual(GroundProfile.resolve(id: "camera.study", in: []), .cameraStudy)
        XCTAssertEqual(GroundProfile.all.map(\.id), ["screen.default", "camera.study"])
    }

    func testResolveEmptyCatalogMatchesLegacyBuiltIn() {
        for id in ["screen.default", "camera.study", "stale.uuid", ""] {
            XCTAssertEqual(GroundProfile.resolve(id: id, in: []), GroundProfile.builtIn(id: id))
        }
    }

    func testResolveUserProfileByIdAndBuiltInsWinIdCollisions() {
        let user = GroundProfile(
            id: "u1", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen], isBuiltIn: false,
            displayName: "Mine"
        )
        XCTAssertEqual(GroundProfile.resolve(id: "u1", in: [user]), user)
        // A user entry reusing a built-in id can never shadow the built-in.
        let masquerader = user.with(
            displayName: "Fake screen", instruction: nil, promptTemplate: nil, modelBinding: nil, moduleOverrides: .none
        )
        XCTAssertEqual(
            GroundProfile.resolve(id: "screen.default", in: [masquerader]), .screenDefault
        )
    }

    // MARK: Eligible grounds + with(activeGrounds:)

    func testMultiGroundEligibleIsTheFoldableSet() {
        // Only the one-shot, foldable grounds — never the interactive (camera/file) or non-capture
        // (voiceInput/agent) ones the fan-out can't commit.
        XCTAssertEqual(Ground.multiGroundEligible, [.screen, .selectedText, .systemAudio])
        for ineligible in [Ground.camera, .file, .voiceInput, .agent] {
            XCTAssertFalse(Ground.multiGroundEligible.contains(ineligible), "\(ineligible) is not foldable")
        }
    }

    func testWithActiveGroundsEditsUserProfileAndKeepsPrimary() {
        let user = GroundProfile(
            id: "u1", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen], isBuiltIn: false, displayName: "Mine"
        )
        // Editing drops the primary from the passed set, but `with` re-inserts it.
        let edited = user.with(
            displayName: user.displayName, instruction: nil, promptTemplate: nil,
            modelBinding: nil, moduleOverrides: .none, activeGrounds: [.systemAudio]
        )
        XCTAssertEqual(edited.activeGrounds, [.screen, .systemAudio], "primaryGround is always present")
    }

    func testWithNilActiveGroundsKeepsExistingGrounds() {
        let user = GroundProfile(
            id: "u1", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen, .selectedText], isBuiltIn: false
        )
        let edited = user.with(
            displayName: "New", instruction: nil, promptTemplate: nil, modelBinding: nil, moduleOverrides: .none
        )
        XCTAssertEqual(edited.activeGrounds, [.screen, .selectedText], "an unspecified ground set is unchanged")
    }

    func testWithActiveGroundsIsIgnoredForBuiltIns() {
        // A built-in's grounds are part of its identity — `with(activeGrounds:)` can never change them.
        let edited = GroundProfile.screenDefault.with(
            displayName: nil, instruction: nil, promptTemplate: nil,
            modelBinding: nil, moduleOverrides: .none, activeGrounds: [.screen, .systemAudio]
        )
        XCTAssertEqual(edited.activeGrounds, GroundProfile.screenDefault.activeGrounds)
        XCTAssertTrue(edited.isBuiltIn)
    }
}

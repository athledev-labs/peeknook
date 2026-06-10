// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The reset-bomb suite for `peeknook.profiles.v1`: every persisted enum and container reachable
/// from a profile must degrade on unknown/corrupt data — a throw anywhere fails the whole catalog
/// decode and nukes every user profile. These tests land BEFORE the catalog can grow an entry.
final class ProfileResetBombTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - GroundProfile new fields

    func testGroundProfileDecodesLegacyBlobWithoutNewFields() throws {
        let legacy = """
        {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
         "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        """
        let profile = try decode(GroundProfile.self, legacy)
        XCTAssertNil(profile.displayName)
        XCTAssertNil(profile.instruction)
        XCTAssertNil(profile.modelBinding)
        XCTAssertEqual(profile.moduleOverrides, .none)
    }

    func testRoundTripPreservesBuiltInJSONShape() throws {
        let data = try JSONEncoder().encode(GroundProfile.screenDefault)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(root.keys),
            ["id", "displayNameKey", "symbol", "primaryGround", "activeGrounds", "isBuiltIn"],
            "A built-in must encode exactly the six legacy keys — the new fields are conditional."
        )
        let decoded = try JSONDecoder().decode(GroundProfile.self, from: data)
        XCTAssertEqual(decoded, .screenDefault)
    }

    func testGroundProfileWithNewFieldsRoundTrips() throws {
        let profile = GroundProfile(
            id: "B6E4A23F-0000-0000-0000-000000000001",
            displayNameKey: "Screen",
            symbol: "macwindow",
            primaryGround: .screen,
            activeGrounds: [.screen, .selectedText],
            isBuiltIn: false,
            displayName: "Chess coach",
            instruction: "You are a patient chess coach.",
            modelBinding: ProfileModelBinding(backend: .openAICompatible, tag: "qwen2-vl"),
            moduleOverrides: ModuleOverrides([.webLookup: true, .speakAnswers: false])
        )
        let decoded = try JSONDecoder().decode(GroundProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
    }

    func testGroundProfileGarbageBindingDoesNotNukeProfile() throws {
        let blob = """
        {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
         "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false,
         "displayName":"Mine","modelBinding":{"backend":"alien"}}
        """
        let profile = try decode(GroundProfile.self, blob)
        XCTAssertEqual(profile.displayName, "Mine")
        XCTAssertEqual(profile.modelBinding?.backend, .ollama, "Unknown backend degrades, never throws.")
        XCTAssertEqual(profile.modelBinding?.tag, "")
    }

    func testInstructionTrimmedAndCappedOnDecode() throws {
        let long = String(repeating: "a", count: 5_000)
        let blob = """
        {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
         "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false,
         "instruction":"  \(long)  "}
        """
        let profile = try decode(GroundProfile.self, blob)
        XCTAssertEqual(profile.instruction?.count, ProfileInstruction.maxLength)

        let whitespaceOnly = """
        {"id":"u2","displayNameKey":"Screen","symbol":"macwindow",
         "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false,
         "instruction":"   \\n  "}
        """
        XCTAssertNil(try decode(GroundProfile.self, whitespaceOnly).instruction)
    }

    // MARK: - ProfileModelBinding

    func testProfileModelBindingUnknownBackendDegradesToOllama() throws {
        let binding = try decode(ProfileModelBinding.self, #"{"backend":"sidecar","tag":"x"}"#)
        XCTAssertEqual(binding.backend, .ollama)
        XCTAssertEqual(binding.tag, "x")
    }

    func testProfileModelBindingMissingTagDefaultsEmpty() throws {
        let binding = try decode(ProfileModelBinding.self, #"{"backend":"ollama"}"#)
        XCTAssertEqual(binding.tag, "")
        XCTAssertFalse(binding.hasUsableTag)
    }

    func testEmptyTagNormalizesToNoBinding() {
        XCTAssertNil(ProfileModelBinding(backend: .ollama, normalizingTag: "   "))
        XCTAssertEqual(
            ProfileModelBinding(backend: .ollama, normalizingTag: " gemma4:e2b ")?.tag,
            "gemma4:e2b"
        )
    }

    func testProfileModelBindingRoundTrips() throws {
        let binding = ProfileModelBinding(backend: .openAICompatible, tag: "gpt-4o")
        let decoded = try JSONDecoder().decode(
            ProfileModelBinding.self, from: JSONEncoder().encode(binding)
        )
        XCTAssertEqual(decoded, binding)
        XCTAssertEqual(decoded.modelReference, ModelReference(backend: .openAICompatible, tag: "gpt-4o"))
    }

    // MARK: - ModuleOverrides

    func testModuleOverridesDropsUnknownModuleID() throws {
        let overrides = try decode(ModuleOverrides.self, #"{"webLookup":true,"telepathy":false}"#)
        XCTAssertEqual(overrides.value(for: .webLookup), true)
        XCTAssertEqual(overrides, ModuleOverrides([.webLookup: true]))
    }

    func testModuleOverridesDropsGroundedAndReservedKeys() throws {
        let overrides = try decode(
            ModuleOverrides.self,
            #"{"cameraCapture":true,"screenCapture":false,"agentActions":true,"webLookup":true}"#
        )
        XCTAssertNil(overrides.value(for: .cameraCapture), "A grounded module must never be forced by a blob.")
        XCTAssertNil(overrides.value(for: .screenCapture))
        XCTAssertNil(overrides.value(for: .agentActions))
        XCTAssertEqual(overrides.value(for: .webLookup), true)
    }

    func testModuleOverridesSetIneligibleIsNoOp() {
        var overrides = ModuleOverrides.none
        overrides.set(.cameraCapture, true)
        XCTAssertEqual(overrides, .none)
    }

    func testModuleOverridesAbsentMeansNilInheritNotOff() {
        XCTAssertNil(ModuleOverrides.none.value(for: .webLookup), "Absent = inherit global, never off.")
    }

    func testModuleOverridesRoundTrips() throws {
        let overrides = ModuleOverrides([.voiceInput: false, .webLookup: true])
        let decoded = try JSONDecoder().decode(
            ModuleOverrides.self, from: JSONEncoder().encode(overrides)
        )
        XCTAssertEqual(decoded, overrides)
    }

    // MARK: - ProfileCatalog

    func testProfileCatalogTypeMismatchedSchemaVersionDoesNotThrow() throws {
        let catalog = try decode(ProfileCatalog.self, #"{"schemaVersion":"notAnInt","profiles":[]}"#)
        XCTAssertEqual(catalog.schemaVersion, ProfileCatalog.currentSchemaVersion)
    }

    func testProfileCatalogDropsBuiltInMasqueraders() throws {
        let blob = """
        {"schemaVersion":1,"profiles":[
          {"id":"screen.default","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false},
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":true},
          {"id":"u2","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        let catalog = try decode(ProfileCatalog.self, blob)
        XCTAssertEqual(catalog.profiles.map(\.id), ["u2"], "Built-in ids and isBuiltIn entries filter out.")
    }

    func testProfileCatalogDeDupesFirstWinsAndCorruptEntriesDrop() throws {
        let blob = """
        {"schemaVersion":1,"profiles":[
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false,"displayName":"First"},
          {"this is": "not a profile"},
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false,"displayName":"Second"},
          {"id":"u3","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        let catalog = try decode(ProfileCatalog.self, blob)
        XCTAssertEqual(catalog.profiles.map(\.id), ["u1", "u3"])
        XCTAssertEqual(catalog.profiles.first?.displayName, "First", "Duplicate ids de-dupe first-wins.")
    }

    func testFutureSchemaVersionDecodesProfiles() throws {
        let blob = """
        {"schemaVersion":99,"profiles":[
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        let catalog = try decode(ProfileCatalog.self, blob)
        XCTAssertEqual(catalog.schemaVersion, 99)
        XCTAssertEqual(catalog.profiles.count, 1, "A future schemaVersion must not strand the profiles.")
    }

    func testProfileCatalogRoundTrips() throws {
        let catalog = ProfileCatalog(profiles: [
            GroundProfile(
                id: "B6E4A23F-0000-0000-0000-000000000002",
                displayNameKey: "Screen",
                symbol: "macwindow",
                primaryGround: .screen,
                activeGrounds: [.screen],
                isBuiltIn: false,
                displayName: "Mine",
                instruction: "Be terse."
            )
        ])
        let decoded = try JSONDecoder().decode(ProfileCatalog.self, from: JSONEncoder().encode(catalog))
        XCTAssertEqual(decoded, catalog)
    }

    // MARK: - ProfileInstruction

    func testSanitizedTrimsCapsAndNilsEmpty() {
        XCTAssertNil(ProfileInstruction.sanitized(nil))
        XCTAssertNil(ProfileInstruction.sanitized("   \n "))
        XCTAssertEqual(ProfileInstruction.sanitized("  be kind  "), "be kind")
        XCTAssertEqual(
            ProfileInstruction.sanitized(String(repeating: "x", count: 9_000))?.count,
            ProfileInstruction.maxLength
        )
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Import / export of shareable profile presets. A preset is decoded from an UNTRUSTED source, so the
/// suite proves: lossless round-trip for known fields, tolerant decode (bad/hostile bytes never crash
/// or strand the catalog), built-in masqueraders dropped, unknown grounds dropped, and a clean
/// de-colliding install into a receiving catalog.
@MainActor
final class ProfilePresetTests: XCTestCase {
    private func userProfile(
        id: String = UUID().uuidString,
        name: String = "Shared",
        grounds: Set<Ground> = [.screen, .systemAudio]
    ) -> GroundProfile {
        GroundProfile(
            id: id,
            displayNameKey: "Screen",
            symbol: "macwindow",
            primaryGround: .screen,
            activeGrounds: grounds,
            isBuiltIn: false,
            displayName: name,
            instruction: "Be a careful reviewer.",
            promptTemplate: "Answer as a checklist.",
            modelBinding: ProfileModelBinding(backend: .openAICompatible, tag: "qwen2-vl"),
            moduleOverrides: ModuleOverrides([.webLookup: true, .speakAnswers: false])
        )
    }

    // MARK: - Round-trip

    func testExportImportIsLosslessForKnownFields() throws {
        let profile = userProfile()
        let data = try ProfilePreset.export([profile])
        let imported = ProfilePreset.import(from: data)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.first, profile, "every known field survives the round trip")
    }

    func testExportSetsTheFormatMarker() throws {
        let data = try ProfilePreset.export([userProfile()])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(root["format"] as? String, ProfilePreset.format)
        XCTAssertEqual(root["schemaVersion"] as? Int, ProfilePreset.currentSchemaVersion)
    }

    func testExportDropsBuiltIns() throws {
        let data = try ProfilePreset.export([.screenDefault, userProfile(name: "Mine")])
        let imported = ProfilePreset.import(from: data)
        XCTAssertEqual(imported.map(\.displayName), ["Mine"], "a built-in can never ship in a preset")
    }

    // MARK: - Tolerant decode (hostile / malformed input)

    func testImportOfGarbageBytesYieldsEmptyNeverThrows() {
        XCTAssertEqual(ProfilePreset.import(from: Data("not json at all".utf8)), [])
        XCTAssertEqual(ProfilePreset.import(from: Data()), [])
        XCTAssertEqual(ProfilePreset.import(from: Data("{}".utf8)), [], "no format marker, no profiles")
    }

    func testImportRejectsWrongFormatMarker() {
        let blob = """
        {"format":"some.other.app","schemaVersion":1,"profiles":[
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        XCTAssertEqual(
            ProfilePreset.import(from: Data(blob.utf8)), [],
            "an unrelated JSON file (wrong marker) imports nothing, even when it looks like a preset"
        )
    }

    func testImportDropsCorruptEntriesAndUnknownGroundsButKeepsSiblings() {
        let blob = """
        {"format":"\(ProfilePreset.format)","schemaVersion":1,"profiles":[
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen","telepathy"],"isBuiltIn":false,"displayName":"Keeper"},
          {"garbage":"entry"},
          {"id":"screen.default","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        let imported = ProfilePreset.import(from: Data(blob.utf8))
        XCTAssertEqual(imported.map(\.displayName), ["Keeper"], "corrupt entry + built-in id drop; the good one survives")
        XCTAssertEqual(imported.first?.activeGrounds, [.screen], "the unknown 'telepathy' ground is dropped, never throws")
    }

    func testFutureSchemaVersionStillDecodesProfiles() {
        let blob = """
        {"format":"\(ProfilePreset.format)","schemaVersion":99,"profiles":[
          {"id":"u1","displayNameKey":"Screen","symbol":"macwindow",
           "primaryGround":"screen","activeGrounds":["screen"],"isBuiltIn":false}
        ]}
        """
        XCTAssertEqual(ProfilePreset.import(from: Data(blob.utf8)).count, 1, "a newer schema must not strand profiles")
    }

    // MARK: - Install (de-collision + cap)

    func testInstallableMintsFreshIdsAndPreservesContent() throws {
        let preset = try XCTUnwrap(try? JSONDecoder().decode(
            ProfilePreset.self, from: ProfilePreset.export([userProfile(id: "fixed-id")])
        ))
        let installed = preset.installable(into: .empty)
        XCTAssertEqual(installed.count, 1)
        XCTAssertNotEqual(installed.first?.id, "fixed-id", "install mints a fresh id so it can't overwrite an existing profile")
        XCTAssertNotNil(UUID(uuidString: installed.first?.id ?? ""), "the fresh id is a UUID")
        XCTAssertEqual(installed.first?.displayName, "Shared")
        XCTAssertEqual(installed.first?.promptTemplate, "Answer as a checklist.")
        XCTAssertEqual(installed.first?.activeGrounds, [.screen, .systemAudio])
        XCTAssertFalse(installed.first?.isBuiltIn ?? true)
    }

    func testInstallableRespectsCatalogCapacity() throws {
        let manyExisting = (0..<ProfileCatalog.maxProfiles).map { userProfile(id: "existing-\($0)") }
        let full = ProfileCatalog(profiles: manyExisting)
        XCTAssertEqual(full.profiles.count, ProfileCatalog.maxProfiles)
        let preset = ProfilePreset(profiles: [userProfile()])
        XCTAssertEqual(preset.installable(into: full), [], "a full catalog leaves no room for an import")
    }

    // MARK: - ProfileStore import/export

    func testStoreExportImportRoundTripsAddingFreshProfile() throws {
        let defaults = UserDefaults(suiteName: "peeknook.tests.preset.store")!
        defaults.removePersistentDomain(forName: "peeknook.tests.preset.store")
        let source = ProfileStore(defaults: defaults)
        let made = try XCTUnwrap(source.duplicate(.screenDefault, name: "Reviewer"))
        source.setInstruction(id: made.id, "Be a careful reviewer.")
        source.setPromptTemplate(id: made.id, "Answer as a checklist.")

        let data = try source.exportPreset(ids: [made.id])

        // Import into a DIFFERENT catalog (fresh suite) — the canonical "share with another user" flow.
        let dstDefaults = UserDefaults(suiteName: "peeknook.tests.preset.store.dst")!
        dstDefaults.removePersistentDomain(forName: "peeknook.tests.preset.store.dst")
        let dest = ProfileStore(defaults: dstDefaults)
        let added = dest.importPreset(from: data)

        XCTAssertEqual(added.count, 1)
        XCTAssertNotEqual(added.first?.id, made.id, "the imported profile gets a fresh id")
        XCTAssertEqual(added.first?.instruction, "Be a careful reviewer.")
        XCTAssertEqual(added.first?.promptTemplate, "Answer as a checklist.")
        // Survives a reload (it was persisted).
        XCTAssertEqual(ProfileStore(defaults: dstDefaults).catalog.profiles.count, 1)
    }

    func testStoreImportTwiceCreatesTwoDistinctProfiles() throws {
        let defaults = UserDefaults(suiteName: "peeknook.tests.preset.twice")!
        defaults.removePersistentDomain(forName: "peeknook.tests.preset.twice")
        let store = ProfileStore(defaults: defaults)
        let data = try ProfilePreset.export([userProfile(name: "Dup")])

        let first = store.importPreset(from: data)
        let second = store.importPreset(from: data)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first.first?.id, second.first?.id, "re-importing never overwrites; it adds a distinct copy")
        XCTAssertEqual(store.catalog.profiles.count, 2)
    }

    func testStoreImportOfHostileBytesIsNoOp() {
        let defaults = UserDefaults(suiteName: "peeknook.tests.preset.hostile")!
        defaults.removePersistentDomain(forName: "peeknook.tests.preset.hostile")
        let store = ProfileStore(defaults: defaults)
        let added = store.importPreset(from: Data("💣 not a preset".utf8))
        XCTAssertEqual(added, [], "hostile bytes import nothing")
        XCTAssertEqual(store.catalog.profiles, [], "and never strand the existing catalog")
    }
}

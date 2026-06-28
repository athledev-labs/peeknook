// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class ProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.profileStore")!
        defaults.removePersistentDomain(forName: "peeknook.tests.profileStore")
    }

    private func makeStore() -> ProfileStore {
        ProfileStore(defaults: defaults)
    }

    func testAbsentKeyLoadsEmptyCatalog() {
        let store = makeStore()
        XCTAssertEqual(store.catalog, .empty)
        XCTAssertEqual(store.allProfiles, GroundProfile.all, "Fresh install: built-ins only.")
    }

    func testDuplicateScreenDefaultProducesUUIDCopy() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Copy of Screen"))
        XCTAssertNotEqual(copy.id, GroundProfile.screenDefault.id)
        XCTAssertNotNil(UUID(uuidString: copy.id), "User copies get UUID ids.")
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.primaryGround, .screen)
        XCTAssertEqual(copy.activeGrounds, GroundProfile.screenDefault.activeGrounds)
        XCTAssertEqual(copy.displayName, "Copy of Screen")
        XCTAssertNil(copy.instruction)
    }

    func testDuplicateOfCameraStudyReturnsNil() {
        let store = makeStore()
        XCTAssertNil(
            store.duplicate(.cameraStudy, name: "My camera"),
            "Camera copies are out of v1 — a camera-primary active profile would dead-end ⌘⇧P."
        )
        XCTAssertEqual(store.catalog.profiles, [])
    }

    func testDuplicableBuiltInsExcludesCameraStudy() {
        XCTAssertEqual(makeStore().duplicableBuiltIns.map(\.id), ["screen.default"])
    }

    func testBuiltInsNeverEnterPersistedArray() throws {
        let store = makeStore()
        _ = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        let reloaded = ProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.catalog.profiles.count, 1)
        XCTAssertFalse(reloaded.catalog.profiles[0].isBuiltIn)
        XCTAssertEqual(reloaded.allProfiles.count, GroundProfile.all.count + 1)
    }

    func testUpdateIsNoOpOnBuiltIn() {
        let store = makeStore()
        store.update(.screenDefault)
        XCTAssertEqual(store.catalog.profiles, [])
    }

    func testRenamePersistsLiteralName() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Before"))
        store.rename(id: copy.id, to: "  After  ")
        XCTAssertEqual(store.profile(id: copy.id).displayName, "After")
        XCTAssertEqual(ProfileStore(defaults: defaults).profile(id: copy.id).displayName, "After")

        store.rename(id: copy.id, to: "   ")
        XCTAssertEqual(store.profile(id: copy.id).displayName, "After", "Empty rename keeps the prior name.")
    }

    func testDeleteActiveReturnsTrueAndResolveFallsBack() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        XCTAssertTrue(store.delete(id: copy.id, activeProfileID: copy.id))
        XCTAssertEqual(
            GroundProfile.resolve(id: copy.id, in: store.catalog.profiles), .screenDefault,
            "A deleted active id resolves to the fallback, never strands the user."
        )
    }

    func testDeleteNonActiveReturnsFalse() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        XCTAssertFalse(store.delete(id: copy.id, activeProfileID: GroundProfile.screenDefault.id))
    }

    func testDeleteBuiltInIdIsNoOp() {
        let store = makeStore()
        XCTAssertFalse(store.delete(id: GroundProfile.screenDefault.id, activeProfileID: GroundProfile.screenDefault.id))
        XCTAssertEqual(store.allProfiles.count, GroundProfile.all.count)
    }

    func testPersistAndReloadRoundTripsCatalog() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Round trip"))
        store.update(copy.edited {
            $0.instruction = "Be brief."
            $0.modelBinding = ProfileModelBinding(backend: .ollama, tag: "gemma4:e2b")
            $0.moduleOverrides = ModuleOverrides([.webLookup: true])
        })
        let reloaded = ProfileStore(defaults: defaults)
        let restored = reloaded.profile(id: copy.id)
        XCTAssertEqual(restored.instruction, "Be brief.")
        XCTAssertEqual(restored.modelBinding?.tag, "gemma4:e2b")
        XCTAssertEqual(restored.moduleOverrides.value(for: .webLookup), true)
    }

    /// The reason the `mutate(inout Editable)` seam exists: changing ONE field through it leaves every
    /// other field intact. The old `with(...)` factory took every field explicitly, so a setter that
    /// forgot one silently wiped it; `mutate` makes that class of bug unrepresentable.
    func testMutatePreservesEveryUneditedField() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Rich"))
        // Seed every editable field so a dropped one would be detectable.
        store.setInstruction(id: copy.id, "Be precise.")
        store.setPromptTemplate(id: copy.id, "Use bullet points.")
        store.setModelBinding(id: copy.id, ProfileModelBinding(backend: .ollama, tag: "gemma4:e4b"))
        store.setModuleOverride(id: copy.id, module: .webLookup, enabled: true)
        store.setActiveGrounds([.systemAudio], for: copy.id)

        // Change only the name through the seam.
        store.rename(id: copy.id, to: "Renamed")

        let after = ProfileStore(defaults: defaults).profile(id: copy.id)
        XCTAssertEqual(after.displayName, "Renamed")
        XCTAssertEqual(after.instruction, "Be precise.", "renaming must not drop the instruction")
        XCTAssertEqual(after.promptTemplate, "Use bullet points.", "renaming must not drop the template")
        XCTAssertEqual(after.modelBinding?.tag, "gemma4:e4b", "renaming must not drop the model binding")
        XCTAssertEqual(after.moduleOverrides.value(for: .webLookup), true, "renaming must not drop overrides")
        XCTAssertEqual(after.activeGrounds, [.screen, .systemAudio], "renaming must not drop active grounds")
    }

    /// Freezes the persisted field count AND pins the schema: each built-in encodes to exactly the six
    /// legacy keys and round-trips by value, and the catalog schema version + namespace are unchanged. A
    /// new persisted field, a renamed key, or a schema bump makes this fail — the M1 freeze canary.
    func testBuiltInsEncodeExactlyTheSixLegacyKeysAndRoundTripByValue() throws {
        for builtIn in GroundProfile.all {
            let data = try JSONEncoder().encode(builtIn)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(
                Set(object.keys),
                ["id", "displayNameKey", "symbol", "primaryGround", "activeGrounds", "isBuiltIn"],
                "\(builtIn.id) persists only the legacy keys; a new field here means the count was unfrozen"
            )
            let decoded = try JSONDecoder().decode(GroundProfile.self, from: data)
            XCTAssertEqual(decoded, builtIn, "\(builtIn.id) round-trips by value, not just by key set")
        }
        XCTAssertEqual(ProfileCatalog.currentSchemaVersion, 1, "the persisted schema version is unchanged")
        XCTAssertEqual(ProfileCatalog.defaultsKey, "peeknook.profiles.v1", "the settings namespace is unchanged")
    }

    /// A built-in is immutable through the store: every editor mutator is a no-op on a built-in id, so
    /// the two shipped profiles can never drift or enter the persisted catalog.
    func testBuiltInIsImmutableThroughTheStore() {
        let store = makeStore()
        let id = GroundProfile.screenDefault.id
        store.rename(id: id, to: "Renamed")
        store.setInstruction(id: id, "Be brief.")
        store.setModelBinding(id: id, ProfileModelBinding(backend: .ollama, tag: "x"))
        store.setModuleOverride(id: id, module: .webLookup, enabled: true)
        XCTAssertEqual(store.catalog.profiles, [], "no built-in mutation ever enters the catalog")
        XCTAssertEqual(store.profile(id: id), .screenDefault, "the built-in is unchanged")
    }

    /// A tool profile's own ground survives an unrelated edit ONLY via the primary re-insertion in the
    /// edit seam (`.tool` is deliberately absent from `multiGroundEligible`). Pins that load-bearing line.
    func testToolProfileKeepsItsGroundThroughANonGroundsEdit() throws {
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Solver"))
        XCTAssertEqual(created.activeGrounds, [.tool])
        store.setInstruction(id: created.id, "Explain the line.")   // a non-grounds edit
        XCTAssertEqual(
            ProfileStore(defaults: defaults).profile(id: created.id).activeGrounds, [.tool],
            "the tool ground is re-inserted as primary and survives an unrelated edit + reload"
        )
    }

    /// The new public edit choke point no-ops on an unknown id and on a built-in id, independent of any
    /// one setter routing through it.
    func testMutateIsNoOpOnUnknownAndBuiltInIDs() {
        let store = makeStore()
        store.mutate(id: "does.not.exist") { $0.displayName = "x" }
        store.mutate(id: GroundProfile.screenDefault.id) { $0.instruction = "x" }
        XCTAssertEqual(store.catalog.profiles, [], "neither an unknown nor a built-in id enters the catalog")
        XCTAssertEqual(store.profile(id: GroundProfile.screenDefault.id), .screenDefault, "the built-in is unchanged")
    }

    func testMaxProfilesCapReturnsNil() {
        let store = makeStore()
        for index in 0..<ProfileCatalog.maxProfiles {
            XCTAssertNotNil(store.duplicate(.screenDefault, name: "Copy \(index)"))
        }
        XCTAssertNil(store.duplicate(.screenDefault, name: "One too many"))
        XCTAssertEqual(store.catalog.profiles.count, ProfileCatalog.maxProfiles)
    }

    /// B1 net: a hand-set `camera.study` active id resolves to the built-in (⌘⇧C unaffected);
    /// the store can't have created it, and the picker omits it.
    func testHandSetCameraStudyActiveIDResolvesHarmlessly() {
        XCTAssertEqual(GroundProfile.resolve(id: "camera.study", in: []), .cameraStudy)
    }

    // MARK: - Editor mutations

    func testSetInstructionCapsAndClearsAndPersists() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        store.setInstruction(id: copy.id, String(repeating: "x", count: 9_000))
        XCTAssertEqual(store.profile(id: copy.id).instruction?.count, ProfileInstruction.maxLength)
        XCTAssertEqual(
            ProfileStore(defaults: defaults).profile(id: copy.id).instruction?.count,
            ProfileInstruction.maxLength
        )
        store.setInstruction(id: copy.id, "")
        XCTAssertNil(store.profile(id: copy.id).instruction)
    }

    func testSetAndClearModelBindingPersists() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        store.setModelBinding(id: copy.id, ProfileModelBinding(backend: .ollama, tag: "llava:13b"))
        XCTAssertEqual(
            ProfileStore(defaults: defaults).profile(id: copy.id).modelBinding?.tag, "llava:13b"
        )
        store.setModelBinding(id: copy.id, nil)
        XCTAssertNil(store.profile(id: copy.id).modelBinding, "Clearing falls back to the global model.")
    }

    func testSetModuleOverrideAndClearAll() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        store.setModuleOverride(id: copy.id, module: .webLookup, enabled: true)
        store.setModuleOverride(id: copy.id, module: .speakAnswers, enabled: false)
        store.setModuleOverride(id: copy.id, module: .cameraCapture, enabled: true)  // ineligible: no-op
        let overrides = store.profile(id: copy.id).moduleOverrides
        XCTAssertEqual(overrides.value(for: .webLookup), true)
        XCTAssertEqual(overrides.value(for: .speakAnswers), false)
        XCTAssertNil(overrides.value(for: .cameraCapture))

        store.setModuleOverride(id: copy.id, module: .webLookup, enabled: nil)
        XCTAssertNil(store.profile(id: copy.id).moduleOverrides.value(for: .webLookup), "nil clears one override.")

        store.clearModuleOverrides(id: copy.id)
        XCTAssertEqual(store.profile(id: copy.id).moduleOverrides, .none)
    }

    // MARK: - Active grounds

    func testSetActiveGroundsPersistsAndKeepsPrimary() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))   // primary .screen
        store.setActiveGrounds([.systemAudio], for: copy.id)   // primary deliberately omitted
        XCTAssertEqual(
            store.profile(id: copy.id).activeGrounds, [.screen, .systemAudio],
            "primaryGround is always kept even when the caller omits it"
        )
        XCTAssertEqual(
            ProfileStore(defaults: defaults).profile(id: copy.id).activeGrounds, [.screen, .systemAudio],
            "the new ground set persists across a reload"
        )
    }

    func testSetActiveGroundsSanitizesOutIneligibleGrounds() throws {
        let store = makeStore()
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Mine"))
        // camera/file are interactive and voiceInput/agent are not capture legs — all must drop.
        store.setActiveGrounds([.screen, .selectedText, .systemAudio, .camera, .file, .voiceInput, .agent], for: copy.id)
        XCTAssertEqual(
            store.profile(id: copy.id).activeGrounds, [.screen, .selectedText, .systemAudio],
            "only foldable grounds survive; camera/file/voiceInput/agent are sanitized out"
        )
    }

    func testSetActiveGroundsIsNoOpOnBuiltIn() {
        let store = makeStore()
        store.setActiveGrounds([.screen, .systemAudio], for: GroundProfile.screenDefault.id)
        XCTAssertEqual(store.catalog.profiles, [], "a built-in id never enters the catalog")
        XCTAssertEqual(
            store.profile(id: GroundProfile.screenDefault.id).activeGrounds,
            GroundProfile.screenDefault.activeGrounds,
            "the built-in's grounds are unchanged"
        )
    }

    func testSetActiveGroundsIsNoOpOnUnknownID() {
        let store = makeStore()
        store.setActiveGrounds([.screen, .systemAudio], for: "does.not.exist")
        XCTAssertEqual(store.catalog.profiles, [])
    }

    // MARK: - Tool profiles

    func testCreateToolProfileMintsToolPrimaryWithDefaultHTTPSpec() throws {
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Chess"))
        XCTAssertNotNil(UUID(uuidString: created.id), "tool profiles get a UUID id")
        XCTAssertFalse(created.isBuiltIn)
        XCTAssertEqual(created.primaryGround, .tool)
        XCTAssertEqual(created.activeGrounds, [.tool])
        XCTAssertEqual(created.displayName, "Chess")
        let spec = try XCTUnwrap(created.toolSpec)
        XCTAssertEqual(spec.transport, .http, "the editor never creates a command tool")
        XCTAssertNil(spec.command)
        XCTAssertNil(spec.url, "the seed has no endpoint yet")
        XCTAssertTrue(spec.sendsScreenshot)
        XCTAssertFalse(spec.isUsable, "no URL means the profile degrades to no tool until edited")
    }

    func testCreateToolProfilePersistsAcrossReload() throws {
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Solver"))
        let reloaded = ProfileStore(defaults: defaults).profile(id: created.id)
        XCTAssertEqual(reloaded.primaryGround, .tool)
        XCTAssertEqual(reloaded.displayName, "Solver")
        XCTAssertEqual(reloaded.toolSpec?.transport, .http)
    }

    func testCreateToolProfileDoesNotActivate() throws {
        // Matches "New profile": create does not change which profile is active.
        let store = makeStore()
        _ = try XCTUnwrap(store.createToolProfile(name: "Tool"))
        XCTAssertEqual(store.catalog.profiles.count, 1)
    }

    func testCreateToolProfileCapsAtMaxProfiles() {
        let store = makeStore()
        for index in 0..<ProfileCatalog.maxProfiles {
            XCTAssertNotNil(store.createToolProfile(name: "Tool \(index)"))
        }
        XCTAssertNil(store.createToolProfile(name: "One too many"))
        XCTAssertEqual(store.catalog.profiles.count, ProfileCatalog.maxProfiles)
    }

    func testSetToolSpecRoundTripsAndPersists() throws {
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Chess"))
        store.setToolSpec(id: created.id, ToolSpec(
            transport: .http,
            url: "http://127.0.0.1:7000",
            sendsScreenshot: true,
            sendsText: true,
            outputLabel: "Chess engine analysis",
            timeoutSeconds: 12
        ))
        let restored = ProfileStore(defaults: defaults).profile(id: created.id)
        let spec = try XCTUnwrap(restored.toolSpec)
        XCTAssertEqual(spec.url, "http://127.0.0.1:7000")
        XCTAssertTrue(spec.sendsText)
        XCTAssertEqual(spec.outputLabel, "Chess engine analysis")
        XCTAssertEqual(spec.timeoutSeconds, 12)
        XCTAssertTrue(spec.isUsable)
    }

    func testSetToolSpecForcesHTTPAndDropsCommand() throws {
        // The signed UI must never create or save a `.command` tool: the store rewrites it to HTTP and
        // clears the command, preserving the URL.
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Chess"))
        store.setToolSpec(id: created.id, ToolSpec(
            transport: .command,
            url: "http://127.0.0.1:9000",
            command: "/usr/local/bin/stockfish",
            arguments: ["--uci"]
        ))
        let spec = try XCTUnwrap(store.profile(id: created.id).toolSpec)
        XCTAssertEqual(spec.transport, .http)
        XCTAssertNil(spec.command, "a command tool can never be saved through the editor")
        XCTAssertEqual(spec.url, "http://127.0.0.1:9000")
    }

    func testSetToolSpecAllowsEmptyURLButLeavesItUnusable() throws {
        let store = makeStore()
        let created = try XCTUnwrap(store.createToolProfile(name: "Chess"))
        store.setToolSpec(id: created.id, ToolSpec(transport: .http, url: "   "))
        let spec = try XCTUnwrap(store.profile(id: created.id).toolSpec)
        XCTAssertNil(spec.url, "whitespace normalizes to nil (an in-progress edit)")
        XCTAssertFalse(spec.isUsable)
    }

    func testSetToolSpecIsNoOpOnBuiltInAndUnknownID() {
        let store = makeStore()
        store.setToolSpec(id: GroundProfile.screenDefault.id, ToolSpec(transport: .http, url: "http://127.0.0.1:1"))
        store.setToolSpec(id: "does.not.exist", ToolSpec(transport: .http, url: "http://127.0.0.1:1"))
        XCTAssertEqual(store.catalog.profiles, [], "a built-in id and an unknown id never enter the catalog")
    }
}

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
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: "Be brief.",
            promptTemplate: nil,
            modelBinding: ProfileModelBinding(backend: .ollama, tag: "gemma4:e2b"),
            moduleOverrides: ModuleOverrides([.webLookup: true]),
            toolSpec: nil
        ))
        let reloaded = ProfileStore(defaults: defaults)
        let restored = reloaded.profile(id: copy.id)
        XCTAssertEqual(restored.instruction, "Be brief.")
        XCTAssertEqual(restored.modelBinding?.tag, "gemma4:e2b")
        XCTAssertEqual(restored.moduleOverrides.value(for: .webLookup), true)
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

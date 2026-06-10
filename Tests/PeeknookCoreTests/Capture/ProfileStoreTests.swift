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
            modelBinding: ProfileModelBinding(backend: .ollama, tag: "gemma4:e2b"),
            moduleOverrides: ModuleOverrides([.webLookup: true])
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
}

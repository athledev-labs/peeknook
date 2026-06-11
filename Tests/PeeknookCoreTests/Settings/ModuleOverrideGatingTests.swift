// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Per-profile module overrides: forcing works both ways for eligible modules, absence inherits
/// global, grounded modules can't be forced, camera turns ignore the active screen profile's
/// overrides, and the saveConversation override gates blob + thread writes together.
@MainActor
final class ModuleOverrideGatingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.moduleOverrides")!
        defaults.removePersistentDomain(forName: "peeknook.tests.moduleOverrides")
    }

    private func userProfile(overrides: ModuleOverrides) -> GroundProfile {
        GroundProfile(
            id: "u-gated", displayNameKey: "Screen", symbol: "macwindow",
            primaryGround: .screen, activeGrounds: [.screen, .selectedText], isBuiltIn: false,
            displayName: "Gated", moduleOverrides: overrides
        )
    }

    // MARK: - Module.isEnabled override layer

    func testOverrideForcesEligibleModuleOff() {
        var settings = PeeknookSettings()
        settings.webLookupEnabled = true
        let profile = userProfile(overrides: ModuleOverrides([.webLookup: false]))
        XCTAssertFalse(Module.isEnabled(.webLookup, in: settings, profile: profile))
    }

    func testOverrideForcesEligibleModuleOn() {
        var settings = PeeknookSettings()
        settings.voiceInputEnabled = false
        let profile = userProfile(overrides: ModuleOverrides([.voiceInput: true]))
        XCTAssertTrue(Module.isEnabled(.voiceInput, in: settings, profile: profile))
    }

    func testAbsentOverrideInheritsGlobal() {
        var settings = PeeknookSettings()
        settings.webLookupEnabled = true
        let profile = userProfile(overrides: .none)
        XCTAssertTrue(Module.isEnabled(.webLookup, in: settings, profile: profile))
        settings.webLookupEnabled = false
        XCTAssertFalse(Module.isEnabled(.webLookup, in: settings, profile: profile))
    }

    func testOverrideCannotForceGroundedModule() {
        let settings = PeeknookSettings()
        // ModuleOverrides drops the ineligible key at init, so the profile still derives
        // cameraCapture from its grounds.
        let profile = userProfile(overrides: ModuleOverrides([.cameraCapture: true]))
        XCTAssertFalse(
            Module.isEnabled(.cameraCapture, in: settings, profile: profile),
            "A screen-grounded profile can never gain cameraCapture via an override."
        )
        XCTAssertTrue(Module.isEnabled(.screenCapture, in: settings, profile: profile))
    }

    /// The zero-behavior-change proof: with no overrides, the override layer leaves every
    /// (module × global-flag) verdict identical to the pre-override truth table for both built-ins.
    func testOverrideLayerLeavesBuiltInBehaviorByteIdentical() {
        for flag in [false, true] {
            var settings = PeeknookSettings()
            settings.webLookupEnabled = flag
            settings.voiceInputEnabled = flag
            settings.speakAnswersEnabled = flag
            settings.persistConversation = flag
            settings.suggestFollowUps = flag
            settings.compositeCaptureEnabled = flag
            for profile in [GroundProfile.screenDefault, .cameraStudy] {
                XCTAssertEqual(Module.isEnabled(.webLookup, in: settings, profile: profile), flag)
                XCTAssertEqual(Module.isEnabled(.voiceInput, in: settings, profile: profile), flag)
                XCTAssertEqual(Module.isEnabled(.speakAnswers, in: settings, profile: profile), flag)
                XCTAssertEqual(Module.isEnabled(.saveConversation, in: settings, profile: profile), flag)
                XCTAssertEqual(Module.isEnabled(.suggestFollowUps, in: settings, profile: profile), flag)
                XCTAssertEqual(
                    Module.isEnabled(.screenCapture, in: settings, profile: profile),
                    profile.activeGrounds.contains(.screen)
                )
                XCTAssertEqual(
                    Module.isEnabled(.cameraCapture, in: settings, profile: profile),
                    profile.activeGrounds.contains(.camera)
                )
                XCTAssertEqual(Module.isEnabled(.parallelScreen, in: settings, profile: profile), flag)
                XCTAssertFalse(Module.isEnabled(.agentActions, in: settings, profile: profile))
            }
        }
    }

    // MARK: - Ground-scoped runtime gating

    /// The single profile-source rule survives overrides: a camera-ground turn gates against the
    /// `cameraStudy` literal (no overrides → global), never the active screen profile.
    func testCameraTurnGatesAgainstCameraStudyLiteralNotActiveProfile() throws {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "Overridden"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: nil,
            modelBinding: nil,
            moduleOverrides: ModuleOverrides([.suggestFollowUps: false, .speakAnswers: false])
        ))
        orchestrator.settings.activeProfileID = copy.id
        orchestrator.settings.suggestFollowUps = true

        // The screen profile's overrides bite for screen-ground turns…
        let screenProfile = orchestrator.gatingProfile(forTurnGround: .screen)
        XCTAssertFalse(orchestrator.moduleEnabled(.suggestFollowUps, for: screenProfile))
        // …and are ignored for camera-ground turns (cameraStudy literal → global truth).
        let cameraProfile = orchestrator.gatingProfile(forTurnGround: .camera)
        XCTAssertEqual(cameraProfile.id, GroundProfile.cameraStudy.id)
        XCTAssertTrue(orchestrator.moduleEnabled(.suggestFollowUps, for: cameraProfile))
    }

    // MARK: - saveConversation write gating (blob + thread together)

    func testSaveConversationOverrideGatesBlobAndThreadWritesTogether() async throws {
        let engine = ScriptedEngine(responsesPerCall: [["ok"]])
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(
                previewBeforeInfer: false, textModel: "x", persistConversation: true
            ),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "hello", screenshotBase64: "QUJD")
            ]),
            inference: engine
        )
        let store = ProfileStore(defaults: defaults)
        orchestrator.profileStore = store
        let protection = FixedKeyArchiveProtection()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-tests-override-\(UUID().uuidString)", isDirectory: true)
        let blobStore = CaptureBlobStore(
            directory: directory.appendingPathComponent("blobs", isDirectory: true),
            protection: protection
        )
        let archive = ConversationArchiveStore(
            directory: directory, protection: protection, blobStore: blobStore
        )
        orchestrator.conversationArchive = archive
        orchestrator.captureBlobStore = blobStore

        let copy = try XCTUnwrap(store.duplicate(.screenDefault, name: "No archive"))
        store.update(copy.with(
            displayName: copy.displayName,
            instruction: nil,
            modelBinding: nil,
            moduleOverrides: ModuleOverrides([.saveConversation: false])
        ))
        orchestrator.settings.activeProfileID = copy.id

        XCTAssertFalse(orchestrator.archiveWritesEnabled)
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")

        // No thread saved AND no blob written: nothing to orphan. The first thread save would
        // mint `activeThreadID`; the blob write would set `screenshotBlobID`.
        XCTAssertNil(orchestrator.activeThreadID, "The thread write must be gated off by the profile override.")
        let imageTurn = orchestrator.conversation.first { $0.isImage }
        if case .image(let capture)? = imageTurn?.kind {
            XCTAssertNil(capture.screenshotBlobID, "No blob may be externalized for a gated-off turn.")
        } else {
            XCTFail("Expected an image turn in the conversation.")
        }
    }

    func testSaveConversationOverrideDoesNotPurgeArchive() {
        // Only the GLOBAL toggle purges; a profile override merely stops new writes.
        var settings = PeeknookSettings()
        settings.persistConversation = true
        let overridden = userProfile(overrides: ModuleOverrides([.saveConversation: false]))
        XCTAssertFalse(Module.isEnabled(.saveConversation, in: settings, profile: overridden))
        XCTAssertTrue(
            settings.persistConversation,
            "The global toggle (which alone drives purge-on-disable) is untouched by an override."
        )
    }
}

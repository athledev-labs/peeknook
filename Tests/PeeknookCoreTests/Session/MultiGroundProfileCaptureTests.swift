// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// A profile that declares MORE than one one-shot-capturable ground (screen + system audio) captures
/// each on the single ⌘⇧P hotkey and commits them as ONE multi-ground question. Single-ground
/// profiles stay byte-identical to the pre-fan-out path. Camera/file (interactive) grounds are never
/// auto-fanned-out.
@MainActor
final class MultiGroundProfileCaptureTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.multiGround")!
        defaults.removePersistentDomain(forName: "peeknook.tests.multiGround")
    }

    /// Persist a user profile so a fresh ``ProfileStore`` loads it (the store only appends via
    /// `duplicate`, which copies a built-in's grounds — so a custom ground set goes through the catalog).
    private func storeWithProfile(_ profile: GroundProfile) -> ProfileStore {
        let catalog = ProfileCatalog(profiles: [profile])
        defaults.set(try! JSONEncoder().encode(catalog), forKey: ProfileCatalog.defaultsKey)
        return ProfileStore(defaults: defaults)
    }

    private func screenAudioProfile() -> GroundProfile {
        GroundProfile(
            id: UUID().uuidString,
            displayNameKey: "Screen + Audio",
            symbol: "macwindow",
            primaryGround: .screen,
            activeGrounds: [.screen, .systemAudio],
            isBuiltIn: false,
            displayName: "Screen + Audio"
        )
    }

    private func makeOrchestrator(
        engine: any InferenceEngine,
        profile: GroundProfile,
        previewBeforeInfer: Bool = false
    ) -> SessionOrchestrator {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: previewBeforeInfer, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "screen text", appName: "Keynote"),
                .systemAudio: SystemAudioCaptureProvider(
                    transcriber: StubSystemAudioTranscriber(scriptedTranscript: "deadline moved to Monday")
                ),
            ]),
            inference: engine
        )
        let store = storeWithProfile(profile)
        orchestrator.profileStore = store
        orchestrator.settings.activeProfileID = profile.id
        return orchestrator
    }

    // MARK: - Fan-out

    func testScreenPlusAudioProfileCapturesBothLegsAsOneGroup() async {
        let profile = screenAudioProfile()
        let o = makeOrchestrator(engine: MockInferenceEngine(tokens: ["a"], declaredCapabilities: ["vision"]), profile: profile)

        o.beginCapture()
        let phase = await o.waitForResult("a")
        guard case .result = phase else { return XCTFail("expected a result, got \(phase)") }

        let images = o.conversation.filter(\.isImage)
        XCTAssertEqual(images.count, 2, "screen + audio commit as two legs of one group")
        let groups = Set(images.compactMap(\.compositeGroupID))
        XCTAssertEqual(groups.count, 1, "both legs share exactly one group id")
        guard case .image(let first)? = images.first?.kind,
              case .image(let second)? = images.last?.kind else { return XCTFail("missing legs") }
        XCTAssertEqual(first.ground, .screen, "primary (screen) leg is committed first")
        XCTAssertEqual(second.ground, .systemAudio, "the audio leg follows")
        XCTAssertEqual(o.conversation.last?.kind, .assistant("a"))
    }

    func testMultiGroundRequestFoldsScreenshotAndTranscriptIntoOneMessage() async {
        let profile = screenAudioProfile()
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let o = makeOrchestrator(engine: engine, profile: profile)

        o.beginCapture()
        _ = await o.waitForResult("a")

        let userMessage = engine.requests.last?.messages.last { $0.role == .user }
        let text = try! XCTUnwrap(userMessage?.text)
        XCTAssertTrue(text.contains("SCREENSHOT"), "the screen leg is named as a screenshot")
        XCTAssertTrue(text.contains("Transcript of the system audio:"), "the audio leg reads as a transcript")
        XCTAssertTrue(text.contains("deadline moved to Monday"), "the transcript text rides the message")
        XCTAssertEqual(userMessage?.imagesBase64.count, 1, "only the screen leg carries an image; audio is text-only")
    }

    func testSingleGroundProfileStaysOnTheSingleCapturePath() async {
        // A plain screen profile (the default) must NOT fan out — exactly one image leg, no group id.
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hi")]),
            inference: engine
        )
        o.profileStore = ProfileStore(defaults: defaults)   // built-in screen.default active

        o.beginCapture()
        _ = await o.waitForResult("a")

        let images = o.conversation.filter(\.isImage)
        XCTAssertEqual(images.count, 1, "a single-ground profile commits one leg")
        XCTAssertNil(images.first?.compositeGroupID, "a standalone capture has no group id")
    }

    // MARK: - Interactive grounds are NOT fanned out

    func testCameraInActiveGroundsIsNotAutoFannedOut() async {
        // A profile that lists screen + camera must still run the one-shot screen path: camera is
        // interactive (live preview), never auto-captured on ⌘⇧P. Only the screen leg is committed.
        let profile = GroundProfile(
            id: UUID().uuidString,
            displayNameKey: "Screen + Camera",
            symbol: "macwindow",
            primaryGround: .screen,
            activeGrounds: [.screen, .camera],
            isBuiltIn: false,
            displayName: "Screen + Camera"
        )
        let engine = ScriptedEngine(responsesPerCall: [["a"]])
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "hi"),
                .camera: StubCameraSession(),
            ]),
            inference: engine
        )
        let store = storeWithProfile(profile)
        o.profileStore = store
        o.settings.activeProfileID = profile.id

        o.beginCapture()
        _ = await o.waitForResult("a")

        let images = o.conversation.filter(\.isImage)
        XCTAssertEqual(images.count, 1, "camera is interactive: ⌘⇧P captures only the one-shot screen leg")
        guard case .image(let only)? = images.first?.kind else { return XCTFail("missing leg") }
        XCTAssertEqual(only.ground, .screen)
        XCTAssertNil(images.first?.compositeGroupID, "one captured leg is not a group")
    }

    // MARK: - Preview is bypassed for a multi-ground fan-out

    func testMultiGroundCommitsDirectlyEvenWithPreviewOn() async {
        // Preview-before-infer would misrepresent a turn that folds in an audio transcript (which has
        // no image to preview), so the fan-out commits directly like the composite path.
        let profile = screenAudioProfile()
        let o = makeOrchestrator(
            engine: MockInferenceEngine(tokens: ["a"], declaredCapabilities: ["vision"]),
            profile: profile,
            previewBeforeInfer: true
        )

        o.beginCapture()
        let phase = await o.waitForResult("a")
        guard case .result = phase else { return XCTFail("expected a direct result, got \(phase)") }
        XCTAssertEqual(o.conversation.filter(\.isImage).count, 2)
    }

    // MARK: - Failure of any leg fails the whole turn

    func testFailingAudioLegFailsTheWholeTurnNoPartialCommit() async {
        let profile = screenAudioProfile()
        let o = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "hi"),
                .systemAudio: SystemAudioCaptureProvider(
                    transcriber: StubSystemAudioTranscriber(error: .permissionRequired("Speech Recognition"))
                ),
            ]),
            inference: MockInferenceEngine(tokens: ["a"], declaredCapabilities: ["vision"])
        )
        let store = storeWithProfile(profile)
        o.profileStore = store
        o.settings.activeProfileID = profile.id

        o.beginCapture()
        let phase = await o.waitForFailed()
        guard case .failed = phase else { return XCTFail("a failing leg must fail the turn, got \(phase)") }
        XCTAssertTrue(o.conversation.isEmpty, "a failed multi-ground capture leaves NO partial turn")
    }
}

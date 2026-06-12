// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

// MARK: - Pure FSM transitions

final class SessionPhaseMachineCameraTests: XCTestCase {
    private let context = SessionTransitionContext()

    func testOpenCameraLiveFromIdleResultFailedAndCapturing() {
        // `.capturing` is included for the composite turn: its screen leg is captured first, then the
        // camera opens for the second leg.
        for start in [SessionPhase.idle, .result("a"), .failed(.emptyAnswer), .capturing] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.openCameraLive, context: context), .applied(.cameraLive))
        }
    }

    func testOpenCameraLiveRejectedFromBusyPhases() {
        let preview = CapturePreview(excerpt: "", sourceLabel: "x")
        for start in [SessionPhase.previewing(preview), .cameraLive, .inferring] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.openCameraLive, context: context), .rejected)
        }
    }

    func testShutterOnlyLegalFromCameraLive() {
        var machine = SessionPhaseMachine(phase: .cameraLive)
        XCTAssertEqual(machine.apply(.shutter, context: context), .applied(.capturing))

        var idle = SessionPhaseMachine(phase: .idle)
        XCTAssertEqual(idle.apply(.shutter, context: context), .rejected)
    }

    func testCancelCameraLiveReturnsToIdle() {
        var machine = SessionPhaseMachine(phase: .cameraLive)
        XCTAssertEqual(machine.apply(.cancelCameraLive, context: context), .applied(.idle))
    }

    /// Outside `.cameraLive` the cancel is a NO-OP, not a reject — the host fires it
    /// unconditionally on every nook-collapse, whatever the phase.
    func testCancelCameraLiveOutsideCameraLiveIsNoOp() {
        for start in [SessionPhase.idle, .capturing, .inferring, .result("a"), .failed(.emptyAnswer)] {
            var machine = SessionPhaseMachine(phase: start)
            XCTAssertEqual(machine.apply(.cancelCameraLive, context: context), .noOp)
            XCTAssertEqual(machine.phase, start, "cancelCameraLive must not disturb \(start)")
        }
    }

    func testCameraLiveFailedSurfacesTheFailure() {
        var machine = SessionPhaseMachine(phase: .cameraLive)
        XCTAssertEqual(
            machine.apply(.cameraLiveFailed(.emptyAnswer), context: context),
            .applied(.failed(.emptyAnswer))
        )
        var idle = SessionPhaseMachine(phase: .idle)
        XCTAssertEqual(idle.apply(.cameraLiveFailed(.emptyAnswer), context: context), .rejected)
    }

    /// ⌘⇧P during the live camera preview is a documented no-op.
    func testBeginCaptureRejectedDuringCameraLive() {
        var machine = SessionPhaseMachine(phase: .cameraLive)
        XCTAssertEqual(machine.apply(.beginCapture, context: context), .rejected)
        XCTAssertEqual(machine.phase, .cameraLive)
    }

    func testShutterFeedsTheUnchangedInferencePath() {
        var machine = SessionPhaseMachine(phase: .cameraLive)
        _ = machine.apply(.shutter, context: context)
        XCTAssertEqual(machine.apply(.inferenceStarted, context: context), .applied(.inferring))
        XCTAssertEqual(
            machine.apply(.inferenceCompleted(answer: "a"), context: context),
            .applied(.result("a"))
        )
    }
}

// MARK: - Orchestrator camera flow (teardown on every exit)

@MainActor
final class SessionOrchestratorCameraTests: XCTestCase {
    private func makeOrchestrator(
        session: StubCameraSession,
        tokens: [String] = ["a"]
    ) -> SessionOrchestrator {
        SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([
                .screen: StubCaptureProvider(sampleText: "screen"),
                .camera: session,
            ]),
            inference: MockInferenceEngine(tokens: tokens)
        )
    }

    func testOpenCameraLiveStartsPreview() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)

        orchestrator.openCameraLive()

        XCTAssertEqual(orchestrator.phase, .cameraLive)
        XCTAssertNotNil(orchestrator.activeCameraSession)
        let started = await orchestrator.waitUntil { session.startPreviewCount == 1 }
        XCTAssertTrue(started)
    }

    func testOpenCameraLiveWithoutCameraProviderIsNoOp() {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        orchestrator.openCameraLive()
        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertNil(orchestrator.activeCameraSession)
    }

    func testShutterCommitsCameraTurnAndTearsDownOnce() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.shutter()

        let phase = await orchestrator.waitForResult("a")
        guard case .result = phase else { return XCTFail("Expected result, got \(phase)") }
        XCTAssertEqual(session.stopPreviewCount, 1, "Shutter must tear the preview down exactly once")
        XCTAssertNil(orchestrator.activeCameraSession)
        guard case .image(let capture)? = orchestrator.conversation.first?.kind else {
            return XCTFail("Expected the camera still as the first turn")
        }
        XCTAssertEqual(capture.ground, .camera)
    }

    func testCancelCameraLiveTearsDownAndReturnsToIdle() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.cancelCameraLive()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertEqual(session.stopPreviewCount, 1)
        XCTAssertNil(orchestrator.activeCameraSession)
    }

    /// The host collapse hook and the user's Cancel can both fire for one exit — the second call
    /// must find a nil session and a no-op FSM event, never a double teardown or a crash.
    func testDoubleCancelIsIdempotent() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.cancelCameraLive()
        orchestrator.cancelCameraLive()

        XCTAssertEqual(orchestrator.phase, .idle)
        XCTAssertEqual(session.stopPreviewCount, 1, "Second cancel must find nothing to stop")
    }

    func testStartPreviewFailureSurfacesFailureAndTearsDown() async {
        let session = StubCameraSession()
        session.startPreviewError = CaptureError.permissionRequired("Camera")
        let orchestrator = makeOrchestrator(session: session)

        orchestrator.openCameraLive()

        let phase = await orchestrator.waitForFailed()
        guard case .failed = phase else { return XCTFail("Expected failed, got \(phase)") }
        XCTAssertNil(orchestrator.activeCameraSession)
    }

    func testCaptureStillFailureSurfacesFailureAndTearsDown() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }
        session.captureStillError = CaptureError.failed("simulated")

        orchestrator.shutter()

        let phase = await orchestrator.waitForFailed()
        guard case .failed = phase else { return XCTFail("Expected failed, got \(phase)") }
        XCTAssertEqual(session.stopPreviewCount, 1)
        XCTAssertNil(orchestrator.activeCameraSession)
    }

    /// Cancel racing an in-flight shutter still: the cancel cancels the camera task, so the late
    /// `captureStill` completion must never commit a turn after the user moved on.
    func testCancelDuringInFlightStillCommitsNothing() async {
        let session = StubCameraSession()
        session.captureDelayNanoseconds = 150_000_000
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.shutter()
        // Wait until the capture provably starts, so the cancel lands DURING it (the race we test).
        _ = await orchestrator.waitUntil { session.captureStillCount == 1 }
        orchestrator.cancelCameraLive()

        XCTAssertEqual(orchestrator.phase, .idle)
        // Deterministically wait for the cancelled capture to resolve (it drops, never commits) rather
        // than sleeping a fixed interval and hoping the window was long enough.
        let resolved = await orchestrator.waitUntil { session.captureStillFinishedCount == 1 }
        XCTAssertTrue(resolved, "the in-flight capture resolved")
        XCTAssertTrue(orchestrator.conversation.isEmpty, "A cancelled shutter must not commit a turn")
        XCTAssertEqual(orchestrator.phase, .idle)
    }

    /// `cancel()` / `dismissResult()` / open-thread all run through `abortSessionWork()` — the
    /// teardown backstop for every exit that isn't a camera-specific event.
    func testGeneralCancelAlsoTearsDownTheCamera() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.cancel()

        XCTAssertEqual(session.stopPreviewCount, 1)
        XCTAssertNil(orchestrator.activeCameraSession)
        XCTAssertEqual(orchestrator.phase, .idle)
    }

    /// Readiness keys on the `camera.study` literal: denied Camera TCC surfaces the typed
    /// permission failure (Privacy → Camera recovery) and the session is never started.
    func testOpenCameraLiveWithDeniedCameraPermissionFailsTyped() {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        let suite = "peeknook.tests.camera-denied"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let setup = SetupCoordinator(
            settings: orchestrator.settings,
            defaults: defaults,
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: true, cameraGranted: false) }
        )
        setup.applyTestBypass()           // ollama + model complete…
        setup.skipsLiveProbes = false     // …but probe the injected (camera-denied) status
        orchestrator.setup = setup

        orchestrator.openCameraLive()

        guard case .failed(let failure) = orchestrator.phase else {
            return XCTFail("Expected a typed permission failure, got \(orchestrator.phase)")
        }
        XCTAssertEqual(failure.kind, .permissionRequired(name: "Camera"))
        XCTAssertEqual(failure.primaryRecovery, .openCameraSettings)
        XCTAssertEqual(session.startPreviewCount, 0, "A denied camera must never start the session")
    }

    /// The flip side of the locked invariant: Camera granted opens the live preview even with
    /// Screen Recording denied — camera.study never demands Screen Recording.
    func testOpenCameraLiveIgnoresScreenRecordingState() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        let suite = "peeknook.tests.camera-granted"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let setup = SetupCoordinator(
            settings: orchestrator.settings,
            defaults: defaults,
            permissionStatus: { CapturePermissionStatus(accessibilityTrusted: false, screenRecordingGranted: false, cameraGranted: true) }
        )
        setup.applyTestBypass()
        setup.skipsLiveProbes = false
        orchestrator.setup = setup

        orchestrator.openCameraLive()

        XCTAssertEqual(orchestrator.phase, .cameraLive)
        let started = await orchestrator.waitUntil { session.startPreviewCount == 1 }
        XCTAssertTrue(started)
    }

    /// ⌘⇧P during `.cameraLive` is a no-op: `beginCapture` only proceeds from idle/result, and the
    /// FSM explicitly rejects `beginCapture` in `.cameraLive` as belt-and-braces.
    func testBeginCaptureDuringCameraLiveIsIgnored() async {
        let session = StubCameraSession()
        let orchestrator = makeOrchestrator(session: session)
        orchestrator.openCameraLive()
        _ = await orchestrator.waitUntil { session.isPreviewing }

        orchestrator.beginCapture()

        XCTAssertEqual(orchestrator.phase, .cameraLive)
        XCTAssertTrue(session.isPreviewing, "The live preview must survive a stray capture hotkey")
    }
}

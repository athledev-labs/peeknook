// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Records every capture handed to web lookup so tests can assert the ground gate.
private actor RecordingWebLookup: WebLookupProviding {
    private(set) var captures: [CaptureResult] = []

    func lookup(capture: CaptureResult) async -> WebLookupSnapshot? {
        captures.append(capture)
        return nil
    }
}

/// Screen-slot provider that returns a camera-ground frame, exercising the runTurn ground gate
/// without needing a camera profile.
private struct CameraGroundStubProvider: CaptureProviding {
    func capture(
        scope: CaptureScope,
        quick: Bool,
        encoding: CaptureEncodingParams
    ) async throws -> CaptureResult {
        _ = encoding
        return CaptureResult(
            text: "x",
            sourceLabel: "Camera (live)",
            screenshotBase64: StubCaptureProvider.defaultScreenshotBase64,
            ground: .camera
        )
    }
}

@MainActor
final class SessionOrchestratorTests: XCTestCase {
    /// Web lookup is gated on the ground explicitly: a camera frame must never become a search
    /// query, even though today's camera frames also happen to carry no text/app/window.
    func testWebLookupSkippedForCameraGround() async {
        let webLookup = RecordingWebLookup()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", webLookupEnabled: true),
            captureRegistry: GroundRegistry([.screen: CameraGroundStubProvider()]),
            inference: MockInferenceEngine(tokens: ["a"]),
            webLookup: webLookup
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("a")

        let captures = await webLookup.captures
        XCTAssertTrue(captures.isEmpty, "A camera frame must never become a web search query")
    }

    func testWebLookupStillRunsForScreenGround() async {
        let webLookup = RecordingWebLookup()
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x", webLookupEnabled: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["a"]),
            webLookup: webLookup
        )

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("a")

        let captures = await webLookup.captures
        XCTAssertEqual(captures.count, 1)
        XCTAssertEqual(captures.first?.ground, .screen)
    }

    func testPreviewThenInferStreamsTokens() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: true, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["a", "b"])
        )

        orchestrator.beginCapture()
        let previewPhase = await orchestrator.waitForPreviewing()
        guard case .previewing = previewPhase else {
            XCTFail("Expected previewing, got \(previewPhase)")
            return
        }

        orchestrator.confirmPreview()
        let resultPhase = await orchestrator.waitForResult("ab")
        guard case .result("ab") = resultPhase else {
            XCTFail("Expected result ab, got \(orchestrator.phase)")
            return
        }
    }

    func testSkipPreviewRunsInference() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "x")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForResult("ok")
        guard case .result("ok") = phase else {
            XCTFail("Expected result ok, got \(phase)")
            return
        }
    }

    func testPreviewCarriesWindowIdentity() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: true, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(
                sampleText: "hello",
                sourceLabel: "Vision + OCR text",
                appName: "Safari",
                windowTitle: "peeknook.com"
            )]),
            inference: MockInferenceEngine(tokens: ["a"])
        )

        orchestrator.beginCapture()
        let previewPhase = await orchestrator.waitForPreviewing()
        guard case .previewing(let preview) = previewPhase else {
            XCTFail("Expected previewing, got \(previewPhase)")
            return
        }
        XCTAssertEqual(preview.appName, "Safari")
        XCTAssertEqual(preview.windowTitle, "peeknook.com")
        XCTAssertEqual(preview.targetLabel, "Safari · peeknook.com")
    }

    func testCaptureTargetLabelFallsBackToModalityLabel() {
        let full = CaptureResult(text: nil, sourceLabel: "Front window (vision)", appName: "Safari", windowTitle: "Docs")
        XCTAssertEqual(full.targetLabel, "Safari · Docs")

        let appOnly = CaptureResult(text: nil, sourceLabel: "Front window (vision)", appName: "Xcode")
        XCTAssertEqual(appOnly.targetLabel, "Xcode")

        let titleOnly = CaptureResult(text: nil, sourceLabel: "Front window (vision)", windowTitle: "Untitled")
        XCTAssertEqual(titleOnly.targetLabel, "Untitled")

        let blank = CaptureResult(text: nil, sourceLabel: "Front window (vision)", appName: "   ", windowTitle: "")
        XCTAssertEqual(blank.targetLabel, "Front window (vision)")
    }

    func testCancelDuringCaptureDoesNotCommit() async throws {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "late", captureDelayNanoseconds: 200_000_000)]),
            inference: MockInferenceEngine(tokens: ["nope"])
        )

        orchestrator.beginCapture()
        guard case .capturing = orchestrator.phase else {
            XCTFail("Expected capturing")
            return
        }
        orchestrator.cancel()
        guard case .idle = orchestrator.phase else {
            XCTFail("Expected idle after cancel, got \(orchestrator.phase)")
            return
        }

        let held = await orchestrator.phaseHolding({ if case .idle = $0 { return true }; return false })
        guard case .idle = held else {
            XCTFail("Late capture leaked state: \(held)")
            return
        }
        XCTAssertFalse(orchestrator.hasConversation)
    }

    func testBeginCaptureWithoutReadySetupFailsWithSetupIncomplete() {
        let defaults = UserDefaults(suiteName: "peeknook.tests.setup-incomplete")!
        defaults.removePersistentDomain(forName: "peeknook.tests.setup-incomplete")
        let setup = SetupCoordinator(settings: .default, defaults: defaults)
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "hello")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.setup = setup

        orchestrator.beginCapture()

        guard case .failed(SessionFailure.setupIncomplete) = orchestrator.phase else {
            XCTFail("Expected setupIncomplete failure, got \(orchestrator.phase)")
            return
        }
    }

    func testIncompleteInferenceStreamTransitionsToFailed() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen")]),
            inference: MockInferenceEngine(tokens: ["partial"], sendsCompletion: false)
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForFailed { $0.kind == .generic }
        guard case .failed(let failure) = phase else {
            XCTFail("Expected failed phase, got \(phase)")
            return
        }
        XCTAssertEqual(failure.title, SessionFailure.incompleteAnswerStream.title)
    }

    func testBeginCaptureFromResultStartsFreshCapture() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "again")]),
            inference: MockInferenceEngine(tokens: ["ok"])
        )
        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("ok")

        orchestrator.beginCapture()
        let second = await orchestrator.waitForResult("ok")
        guard case .result("ok") = second else {
            XCTFail("Expected hotkey capture from result, got \(second)")
            return
        }
    }
}

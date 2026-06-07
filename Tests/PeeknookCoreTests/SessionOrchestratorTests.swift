// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

@MainActor
final class SessionOrchestratorTests: XCTestCase {
    func testPreviewThenInferStreamsTokens() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: true, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["a", "b"])
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard case .previewing = orchestrator.phase else {
            XCTFail("Expected previewing, got \(orchestrator.phase)")
            return
        }

        orchestrator.confirmPreview()
        try? await Task.sleep(nanoseconds: 300_000_000)

        guard case .result("ab") = orchestrator.phase else {
            XCTFail("Expected result ab, got \(orchestrator.phase)")
            return
        }
    }

    func testSkipPreviewRunsInference() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "x"),
            inference: MockInferenceEngine(tokens: ["ok"])
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 100_000_000)

        guard case .result("ok") = orchestrator.phase else {
            XCTFail("Expected result ok, got \(orchestrator.phase)")
            return
        }
    }

    func testPreviewCarriesWindowIdentity() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: true, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(
                sampleText: "hello",
                sourceLabel: "Vision + OCR text",
                appName: "Safari",
                windowTitle: "peeknook.com"
            ),
            inference: MockInferenceEngine(tokens: ["a"])
        )

        orchestrator.beginCapture()
        try? await Task.sleep(nanoseconds: 50_000_000)

        guard case .previewing(let preview) = orchestrator.phase else {
            XCTFail("Expected previewing, got \(orchestrator.phase)")
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
}

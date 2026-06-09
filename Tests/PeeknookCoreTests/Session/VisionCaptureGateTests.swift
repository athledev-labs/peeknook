// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The capture path must not silently drop a screenshot on a text-only model. These guard the
/// orchestrator gate added in Slice 0b: block on an authoritative text-only verdict, never block on
/// an unknown (uninstalled / older-runtime) one.
@MainActor
final class VisionCaptureGateTests: XCTestCase {
    func testTextOnlyModelBlocksCaptureBeforeStreaming() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "llama3:8b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(
                tokens: ["should-not-stream"],
                declaredCapabilities: ["completion"]   // installed, no vision → .textOnly
            )
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForFailed { failure in
            if case .modelLacksVision(let tag) = failure.kind { return tag == "llama3:8b" }
            return false
        }
        guard case .failed(let failure) = phase, case .modelLacksVision = failure.kind else {
            XCTFail("Expected modelLacksVision failure, got \(phase)")
            return
        }
        XCTAssertEqual(failure.primaryRecovery, .switchModel)
        // The text-only model must never receive the screenshot: nothing was streamed.
        XCTAssertEqual(orchestrator.streamedAnswer, "")
    }

    func testVisionModelProceedsToInference() async {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(
                tokens: ["ok"],
                declaredCapabilities: ["completion", "vision"]
            )
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForResult("ok")
        guard case .result("ok") = phase else {
            XCTFail("Expected result ok, got \(phase)")
            return
        }
    }

    func testUnknownVisionCapabilityDoesNotBlockCapture() async {
        // Default declaredCapabilities == nil simulates a not-installed / older runtime → .unknown,
        // which must NOT block (the existing orchestrator tests rely on this path staying open).
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, textModel: "gemma4:e4b"),
            capture: StubCaptureProvider(sampleText: "hello"),
            inference: MockInferenceEngine(tokens: ["ok"])
        )

        orchestrator.beginCapture()
        let phase = await orchestrator.waitForResult("ok")
        guard case .result("ok") = phase else {
            XCTFail("Expected result ok (unknown vision must not block), got \(phase)")
            return
        }
    }
}

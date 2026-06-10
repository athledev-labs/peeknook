// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class SessionPhaseMachineTests: XCTestCase {
    func testIdleBeginCaptureMovesToCapturing() {
        var machine = SessionPhaseMachine()
        let result = machine.apply(.beginCapture, context: .init())
        guard case .applied(.capturing) = result else {
            return XCTFail("Expected capturing, got \(result)")
        }
    }

    func testResultBeginCaptureMovesToCapturing() {
        var machine = SessionPhaseMachine(phase: .result("hi"))
        let result = machine.apply(.beginCapture, context: .init(hasConversation: true))
        guard case .applied(.capturing) = result else {
            return XCTFail("Expected capturing, got \(result)")
        }
    }

    func testInferringBeginCaptureRejected() {
        var machine = SessionPhaseMachine(phase: .inferring)
        XCTAssertEqual(machine.apply(.beginCapture, context: .init()), .rejected)
    }

    func testCapturingPreviewTransition() {
        var machine = SessionPhaseMachine(phase: .capturing)
        let preview = CapturePreview(excerpt: "x", sourceLabel: "vision")
        let result = machine.apply(.capturePreviewing(preview), context: .init())
        guard case .applied(.previewing(preview)) = result else {
            return XCTFail("Expected previewing, got \(result)")
        }
    }

    func testInferenceLifecycle() {
        var machine = SessionPhaseMachine(phase: .capturing)
        XCTAssertEqual(machine.apply(.inferenceStarted, context: .init()), .applied(.inferring))
        XCTAssertEqual(
            machine.apply(.inferenceCompleted(answer: "ok"), context: .init()),
            .applied(.result("ok"))
        )
    }

    func testInferenceEmptyFails() {
        var machine = SessionPhaseMachine(phase: .inferring)
        guard case .applied(.failed) = machine.apply(.inferenceEmpty, context: .init()) else {
            return XCTFail("Expected failed")
        }
    }

    func testFinishChatFromResult() {
        var machine = SessionPhaseMachine(phase: .result("hi"))
        XCTAssertEqual(machine.apply(.finishChat, context: .init()), .applied(.idle))
    }

    func testResumeChatRequiresConversation() {
        var machine = SessionPhaseMachine(phase: .idle)
        XCTAssertEqual(machine.apply(.resumeChat(answer: "hi"), context: .init(hasConversation: false)), .rejected)
        XCTAssertEqual(machine.apply(.resumeChat(answer: "hi"), context: .init(hasConversation: true)), .applied(.result("hi")))
    }

    func testRetryCaptureFromFailed() {
        var machine = SessionPhaseMachine(phase: .failed(.emptyAnswer))
        XCTAssertEqual(machine.apply(.retryCapture, context: .init()), .applied(.capturing))
    }

    func testInferenceStartedFromFailed() {
        var machine = SessionPhaseMachine(phase: .failed(.emptyAnswer))
        XCTAssertEqual(machine.apply(.inferenceStarted, context: .init()), .applied(.inferring))
    }

    func testSetupNotReadyFromIdle() {
        var machine = SessionPhaseMachine(phase: .idle)
        guard case .applied(.failed) = machine.apply(.setupNotReady, context: .init()) else {
            return XCTFail("Expected setup failure")
        }
    }
}

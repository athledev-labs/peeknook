// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Inputs that drive the session phase machine. Side effects (capture, inference, archive) stay
/// outside; the machine only decides whether a transition is legal and what the next phase is.
public enum SessionEvent: Sendable, Equatable {
    case beginCapture
    case setupNotReady
    case capturePreviewing(CapturePreview)
    case captureFailed(SessionFailure)
    case inferenceStarted
    case inferenceCompleted(answer: String)
    case inferenceEmpty
    case inferenceFailed(SessionFailure)
    case finishChat
    case resumeChat(answer: String)
    case cancelPreservingResult(answer: String)
    case cancelToIdle
    case dismissToIdle
    case retryCapture
    case openThreadRestored(answer: String)
    case deleteActiveThreadToIdle
    /// idle/result/failed → `.cameraLive` (open the live camera preview).
    case openCameraLive
    /// `.cameraLive` → `.capturing`: the still is taken; from there the capture path is the
    /// unchanged commit → runTurn → result pipeline.
    case shutter
    /// `.cameraLive` → `.idle`. Outside `.cameraLive` this is a **no-op, not a reject**, so the
    /// host's nook-collapse teardown can fire it unconditionally on every collapse.
    case cancelCameraLive
    /// `.cameraLive` → `.failed` (startPreview / captureStill error surface).
    case cameraLiveFailed(SessionFailure)
}

/// Guards the FSM needs that are not encoded in the phase enum itself.
public struct SessionTransitionContext: Sendable, Equatable {
    public var hasConversation: Bool
    public var isContextBlocked: Bool
    public var setupReady: Bool
    public var previewBeforeInfer: Bool
    public var pendingCaptureAvailable: Bool

    public init(
        hasConversation: Bool = false,
        isContextBlocked: Bool = false,
        setupReady: Bool = true,
        previewBeforeInfer: Bool = false,
        pendingCaptureAvailable: Bool = false
    ) {
        self.hasConversation = hasConversation
        self.isContextBlocked = isContextBlocked
        self.setupReady = setupReady
        self.previewBeforeInfer = previewBeforeInfer
        self.pendingCaptureAvailable = pendingCaptureAvailable
    }
}

public enum SessionTransitionResult: Sendable, Equatable {
    case applied(SessionPhase)
    case rejected
    case noOp
}

/// Pure finite-state machine for ``SessionPhase``. Testable without async or MainActor.
public struct SessionPhaseMachine: Sendable {
    public private(set) var phase: SessionPhase = .idle

    public init(phase: SessionPhase = .idle) {
        self.phase = phase
    }

    public mutating func apply(
        _ event: SessionEvent,
        context: SessionTransitionContext
    ) -> SessionTransitionResult {
        switch event {
        case .beginCapture:
            return applyBeginCapture(context: context)
        case .setupNotReady:
            return applySetupNotReadyFromActive()
        case .capturePreviewing(let preview):
            guard case .capturing = phase else { return .rejected }
            phase = .previewing(preview)
            return .applied(phase)
        case .captureFailed(let failure):
            guard case .capturing = phase else { return .rejected }
            phase = .failed(failure)
            return .applied(phase)
        case .inferenceStarted:
            switch phase {
            case .capturing, .previewing, .result:
                phase = .inferring
                return .applied(phase)
            default:
                return .rejected
            }
        case .inferenceCompleted(let answer):
            guard case .inferring = phase else { return .rejected }
            phase = .result(answer)
            return .applied(phase)
        case .inferenceEmpty:
            guard case .inferring = phase else { return .rejected }
            phase = .failed(.emptyAnswer)
            return .applied(phase)
        case .inferenceFailed(let failure):
            guard case .inferring = phase else { return .rejected }
            phase = .failed(failure)
            return .applied(phase)
        case .finishChat:
            guard case .result = phase else { return .rejected }
            phase = .idle
            return .applied(phase)
        case .resumeChat(let answer):
            guard case .idle = phase, context.hasConversation else { return .rejected }
            phase = .result(answer)
            return .applied(phase)
        case .cancelPreservingResult(let answer):
            phase = .result(answer)
            return .applied(phase)
        case .cancelToIdle:
            phase = .idle
            return .applied(phase)
        case .dismissToIdle:
            phase = .idle
            return .applied(phase)
        case .retryCapture:
            guard case .failed = phase else { return .rejected }
            phase = .capturing
            return .applied(phase)
        case .openThreadRestored(let answer):
            phase = .result(answer)
            return .applied(phase)
        case .deleteActiveThreadToIdle:
            phase = .idle
            return .applied(phase)
        case .openCameraLive:
            return applyOpenCameraLive()
        case .shutter:
            guard case .cameraLive = phase else { return .rejected }
            phase = .capturing
            return .applied(phase)
        case .cancelCameraLive:
            guard case .cameraLive = phase else { return .noOp }
            phase = .idle
            return .applied(phase)
        case .cameraLiveFailed(let failure):
            guard case .cameraLive = phase else { return .rejected }
            phase = .failed(failure)
            return .applied(phase)
        }
    }

    private mutating func applyBeginCapture(context: SessionTransitionContext) -> SessionTransitionResult {
        switch phase {
        case .idle, .result, .failed:
            phase = .capturing
            return .applied(phase)
        case .capturing, .previewing, .cameraLive, .inferring:
            // ⌘⇧P during the live camera preview is a documented no-op, not a default fallthrough.
            return .rejected
        }
    }

    private mutating func applyOpenCameraLive() -> SessionTransitionResult {
        switch phase {
        case .idle, .result, .failed:
            phase = .cameraLive
            return .applied(phase)
        case .capturing, .previewing, .cameraLive, .inferring:
            return .rejected
        }
    }

    private mutating func applySetupNotReadyFromActive() -> SessionTransitionResult {
        switch phase {
        case .idle, .result:
            phase = .failed(.setupIncomplete)
            return .applied(phase)
        default:
            return .rejected
        }
    }
}

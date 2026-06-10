// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A one-tap path out of a failure. The view layer maps each case to a label, symbol, and
/// handler, core stays free of presentation so copy and routing live next to the buttons.
public enum RecoveryAction: Equatable, Sendable {
    case tryAgain
    case openSetup
    case checkOllama
    case downloadModel(tag: String)
    case switchModel
    case openScreenRecordingSettings
    case openAccessibilitySettings
    case openCameraSettings
}

public extension CapturePermission {
    /// The recovery a missing permission offers. Screen Recording / Accessibility / Camera open
    /// their Privacy panes directly; Microphone / Speech Recognition fall back to the setup
    /// drill-in until the voice profiles add their dedicated panes (no shipped profile requires
    /// them yet).
    var recoveryAction: RecoveryAction {
        switch self {
        case .screenRecording: return .openScreenRecordingSettings
        case .accessibility:   return .openAccessibilitySettings
        case .camera:          return .openCameraSettings
        case .microphone, .speechRecognition: return .openSetup
        }
    }
}

/// Structured replacement for the old `.failed(String)` payload. Distinct cases carry human
/// title + explanation and a primary (and optional secondary) ``RecoveryAction`` so views render
/// intentional recovery UI instead of matching on raw error strings.
public struct SessionFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case setupIncomplete
        case ollamaUnreachable
        case modelMissing(tag: String)
        case modelLacksVision(tag: String)
        case captureFailed
        case permissionRequired(name: String)
        case emptyAnswer
        case generic
    }

    public let kind: Kind
    public let title: String
    public let message: String
    public let primaryRecovery: RecoveryAction
    public let secondaryRecovery: RecoveryAction?
    /// Raw technical hint (e.g. an Ollama error body or a CLI command), surfaced small, optional.
    public let technicalDetail: String?

    public init(
        kind: Kind,
        title: String,
        message: String,
        primaryRecovery: RecoveryAction,
        secondaryRecovery: RecoveryAction? = nil,
        technicalDetail: String? = nil
    ) {
        self.kind = kind
        self.title = title
        self.message = message
        self.primaryRecovery = primaryRecovery
        self.secondaryRecovery = secondaryRecovery
        self.technicalDetail = technicalDetail
    }
}

public extension SessionFailure {
    /// Capture was blocked because Ollama / model / Screen Recording aren't all ready.
    static let setupIncomplete = SessionFailure(
        kind: .setupIncomplete,
        title: "Finish setup first",
        message: "Peeknook needs Ollama running, a model installed, and Screen Recording allowed before it can capture.",
        primaryRecovery: .openSetup
    )

    /// Ollama closed the stream before sending a completion event.
    static let incompleteAnswerStream = SessionFailure(
        kind: .generic,
        title: "Answer stream ended early",
        message: "Ollama stopped before finishing the response. Try again, or check that Ollama is still running.",
        primaryRecovery: .tryAgain,
        secondaryRecovery: .checkOllama
    )

    /// The model completed but streamed no text (often a reasoning model spending its budget on
    /// hidden thinking), retrying usually clears it, or switch models.
    static let emptyAnswer = SessionFailure(
        kind: .emptyAnswer,
        title: "No answer came back",
        message: "The model finished without producing any text. Try again on this screenshot, or switch to a different model.",
        primaryRecovery: .tryAgain,
        secondaryRecovery: .switchModel
    )

    /// The selected model can't read images, so the captured screenshot would be silently ignored.
    /// Blocked before any request is sent — the screenshot never reaches a model that can't use it.
    static func modelLacksVision(tag: String) -> SessionFailure {
        SessionFailure(
            kind: .modelLacksVision(tag: tag),
            title: "This model can't see images",
            message: "“\(tag)” is a text-only model, so it would ignore the screenshot. Switch to a vision model to analyze captures.",
            primaryRecovery: .switchModel
        )
    }

    static func generic(message: String) -> SessionFailure {
        SessionFailure(
            kind: .generic,
            title: "Something went wrong",
            message: message,
            primaryRecovery: .tryAgain
        )
    }

    /// A required capture permission for the active profile isn't granted. Typed groundwork for the
    /// per-profile readiness matrix — the camera PR routes a failed `readiness(for:)` through this so
    /// each missing permission gets its own recovery, instead of the opaque `.setupIncomplete`.
    static func permissionRequired(_ permission: CapturePermission) -> SessionFailure {
        SessionFailure(
            kind: .permissionRequired(name: permission.displayName),
            title: "\(permission.displayName) is off",
            message: "Allow \(permission.displayName) in System Settings → Privacy & Security, then try again.",
            primaryRecovery: permission.recoveryAction,
            secondaryRecovery: .tryAgain
        )
    }

    static func from(captureError: CaptureError) -> SessionFailure {
        switch captureError {
        case .noContent:
            return SessionFailure(
                kind: .captureFailed,
                title: "Couldn't read the screen",
                message: "Peeknook captured nothing to send. Make sure Screen Recording is allowed, then try again.",
                primaryRecovery: .openScreenRecordingSettings,
                secondaryRecovery: .tryAgain
            )
        case .permissionRequired(let name):
            // Per-permission routing: match the display name back to its typed permission so the
            // recovery opens the RIGHT Privacy pane (a substring heuristic once sent Camera to the
            // Accessibility pane).
            let permission = CapturePermission.allCases.first { $0.displayName == name }
            return SessionFailure(
                kind: .permissionRequired(name: name),
                title: "\(name) is off",
                message: "Allow \(name) in System Settings → Privacy & Security, then try again.",
                primaryRecovery: permission?.recoveryAction ?? .openSetup,
                secondaryRecovery: .tryAgain
            )
        case .failed(let message):
            return SessionFailure(
                kind: .captureFailed,
                title: "Capture failed",
                message: message,
                primaryRecovery: .tryAgain
            )
        }
    }

    /// Backend-aware: the error cases are generic slots (`.ollamaUnreachable` is "the inference
    /// server is unreachable"), so the *copy* must name the server the user actually configured —
    /// an OpenAI-compatible connection failure claiming "Ollama isn't responding" sends them
    /// debugging the wrong process. Defaulted to `.ollama` so existing call sites are unchanged.
    static func from(
        inferenceError: InferenceError,
        backend: InferenceBackend = .ollama
    ) -> SessionFailure {
        let ollama = backend == .ollama
        switch inferenceError {
        case .invalidBaseURL:
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: ollama ? "Can't reach Ollama" : "Can't reach the inference server",
                message: ollama
                    ? "The Ollama server address in Settings looks invalid. Check it, then try again."
                    : "The inference server address in Settings looks invalid. Check it, then try again.",
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .insecureRemoteHTTP:
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: ollama ? "Remote Ollama needs HTTPS" : "Remote server needs HTTPS",
                message: "Screenshots would leave this Mac in cleartext over HTTP. Use https:// in Settings, or enable “Allow insecure HTTP” under Answer model → Advanced.",
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .ollamaUnreachable(let message):
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: ollama ? "Ollama isn't responding" : "Your inference server isn't responding",
                message: message,
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .modelMissing(let model, let hint):
            if ollama {
                return SessionFailure(
                    kind: .modelMissing(tag: model),
                    title: "Model not installed",
                    message: "“\(model)” isn't downloaded yet. Download it, or switch to a model you already have.",
                    primaryRecovery: .downloadModel(tag: model),
                    secondaryRecovery: .switchModel,
                    technicalDetail: hint
                )
            }
            // No download path on an OpenAI-compatible server — the user loads models there.
            return SessionFailure(
                kind: .modelMissing(tag: model),
                title: "Model not loaded",
                message: "“\(model)” isn't available on your inference server. Load it there, or pick a model the server lists.",
                primaryRecovery: .switchModel,
                secondaryRecovery: .tryAgain,
                technicalDetail: hint
            )
        case .http(let status, let message):
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: ollama ? "Ollama returned an error" : "The inference server returned an error",
                message: message,
                primaryRecovery: .tryAgain,
                secondaryRecovery: .checkOllama,
                technicalDetail: "HTTP \(status)"
            )
        }
    }

    /// Best-effort mapping for an arbitrary error thrown during inference.
    static func from(error: Error, backend: InferenceBackend = .ollama) -> SessionFailure {
        if let inference = error as? InferenceError {
            return .from(inferenceError: inference, backend: backend)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .timedOut, .cannotFindHost, .dnsLookupFailed:
                return .from(
                    inferenceError: .ollamaUnreachable(
                        backend == .ollama
                            ? "Lost connection to Ollama. Check that it is still running, then try again."
                            : "Lost connection to the inference server. Check that it is still running, then try again."
                    ),
                    backend: backend
                )
            default:
                break
            }
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .generic(message: message)
    }
}

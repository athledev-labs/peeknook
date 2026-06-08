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
}

/// Structured replacement for the old `.failed(String)` payload. Distinct cases carry human
/// title + explanation and a primary (and optional secondary) ``RecoveryAction`` so views render
/// intentional recovery UI instead of matching on raw error strings.
public struct SessionFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case setupIncomplete
        case ollamaUnreachable
        case modelMissing(tag: String)
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

    /// The model completed but streamed no text (often a reasoning model spending its budget on
    /// hidden thinking), retrying usually clears it, or switch models.
    static let emptyAnswer = SessionFailure(
        kind: .emptyAnswer,
        title: "No answer came back",
        message: "The model finished without producing any text. Try again, or switch to a different model.",
        primaryRecovery: .tryAgain,
        secondaryRecovery: .switchModel
    )

    static func generic(message: String) -> SessionFailure {
        SessionFailure(
            kind: .generic,
            title: "Something went wrong",
            message: message,
            primaryRecovery: .tryAgain
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
            let isScreen = name.lowercased().contains("screen")
            return SessionFailure(
                kind: .permissionRequired(name: name),
                title: "\(name) is off",
                message: "Allow \(name) in System Settings → Privacy & Security, then try again.",
                primaryRecovery: isScreen ? .openScreenRecordingSettings : .openAccessibilitySettings,
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

    static func from(inferenceError: InferenceError) -> SessionFailure {
        switch inferenceError {
        case .invalidBaseURL:
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: "Can't reach Ollama",
                message: "The Ollama server address in Settings looks invalid. Check it, then try again.",
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .insecureRemoteHTTP:
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: "Remote Ollama needs HTTPS",
                message: "Screenshots would leave this Mac in cleartext over HTTP. Use https:// in Settings, or enable “Allow insecure HTTP” under Vision → Advanced.",
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .ollamaUnreachable(let message):
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: "Ollama isn't responding",
                message: message,
                primaryRecovery: .checkOllama,
                secondaryRecovery: .tryAgain
            )
        case .modelMissing(let model, let hint):
            return SessionFailure(
                kind: .modelMissing(tag: model),
                title: "Model not installed",
                message: "“\(model)” isn't downloaded yet. Download it, or switch to a model you already have.",
                primaryRecovery: .downloadModel(tag: model),
                secondaryRecovery: .switchModel,
                technicalDetail: hint
            )
        case .http(let status, let message):
            return SessionFailure(
                kind: .ollamaUnreachable,
                title: "Ollama returned an error",
                message: message,
                primaryRecovery: .tryAgain,
                secondaryRecovery: .checkOllama,
                technicalDetail: "HTTP \(status)"
            )
        }
    }

    /// Best-effort mapping for an arbitrary error thrown during inference.
    static func from(error: Error) -> SessionFailure {
        if let inference = error as? InferenceError {
            return .from(inferenceError: inference)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
                 .timedOut, .cannotFindHost, .dnsLookupFailed:
                return .from(
                    inferenceError: .ollamaUnreachable(
                        "Lost connection to Ollama. Check that it is still running, then try again."
                    )
                )
            default:
                break
            }
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return .generic(message: message)
    }
}

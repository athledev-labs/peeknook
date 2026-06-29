// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case capturing
    case previewing(CapturePreview)
    /// Pre-capture live camera preview (shutter not pressed). Distinct from `.previewing`, which is
    /// the *post*-capture confirm step. Deliberately payload-free: the live session controller is a
    /// `@MainActor AnyObject` and would break this enum's derived `Equatable`/`Sendable` — the
    /// orchestrator holds it instead (`activeCameraSession`).
    case cameraLive
    /// Ephemeral live caption surface (on-device transcription to translated subtitles). Like
    /// `.cameraLive` it is deliberately payload-free: the transient caption state + transcriber are a
    /// `@MainActor` controller-shaped concern the orchestrator holds (`liveCaption`), so keeping them out
    /// of the enum preserves its derived `Equatable`/`Sendable` and avoids per-token FSM churn.
    case captioning
    case inferring
    case result(String)
    case failed(SessionFailure)
}

public extension SessionPhase {
    /// True when the current failure card already names a missing setup prerequisite — `.setupIncomplete`
    /// (Ollama / model / Screen Recording not all ready) or `.permissionRequired` (a specific permission,
    /// e.g. Camera, off). The idle home uses this to SUPPRESS the standing "finish setup" banner so a
    /// capture-while-not-ready shows ONE coherent message — the precise card, not the card AND the generic
    /// banner beneath it. (The banner lives in the scrolling region and the card in the fixed block below,
    /// so today they stack as two messages.) Genuine failures of a different class — Ollama dropped
    /// mid-answer, empty answer, capture failed — return false and keep the banner, whose "finish setup"
    /// nudge is still independently true and unaddressed by that card.
    var suppressesSetupBanner: Bool {
        guard case .failed(let failure) = self else { return false }
        switch failure.kind {
        case .setupIncomplete, .permissionRequired:
            return true
        default:
            return false
        }
    }
}

public struct CapturePreview: Equatable, Sendable {
    public var excerpt: String
    /// Capture *modality* summary, e.g. "Vision + selected text".
    public var sourceLabel: String
    /// Owning app of the captured window, e.g. "Safari".
    public var appName: String?
    /// Captured window title, e.g. "peeknook.com".
    public var windowTitle: String?
    /// JPEG base64 for preview thumbnail in the notch.
    public var screenshotBase64: String?
    /// Which ground produced the pending capture — the confirm card's trust line derives from it.
    public var ground: Ground

    public init(
        excerpt: String,
        sourceLabel: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshotBase64: String? = nil,
        ground: Ground = .screen
    ) {
        self.excerpt = excerpt
        self.sourceLabel = sourceLabel
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshotBase64 = screenshotBase64
        self.ground = ground
    }

    /// Mirror of `CaptureResult` for a capture the user is about to confirm.
    public init(capture: CaptureResult) {
        self.init(
            excerpt: capture.previewExcerpt,
            sourceLabel: capture.sourceLabel,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            screenshotBase64: capture.screenshotBase64,
            ground: capture.ground
        )
    }

    /// *Which* window the model will see, "Safari, peeknook.com" or a fallback. Camera frames
    /// label by ground, mirroring ``CaptureResult/targetLabel`` so the trust line never drifts.
    public var targetLabel: String {
        switch ground {
        case .camera: "Camera"
        default: captureTargetLabel(appName: appName, windowTitle: windowTitle, fallback: sourceLabel)
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SessionPhase: Equatable, Sendable {
    case idle
    case capturing
    case previewing(CapturePreview)
    case inferring
    case result(String)
    case failed(SessionFailure)
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

    public init(
        excerpt: String,
        sourceLabel: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshotBase64: String? = nil
    ) {
        self.excerpt = excerpt
        self.sourceLabel = sourceLabel
        self.appName = appName
        self.windowTitle = windowTitle
        self.screenshotBase64 = screenshotBase64
    }

    /// Mirror of `CaptureResult` for a capture the user is about to confirm.
    public init(capture: CaptureResult) {
        self.init(
            excerpt: capture.previewExcerpt,
            sourceLabel: capture.sourceLabel,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            screenshotBase64: capture.screenshotBase64
        )
    }

    /// *Which* window the model will see, "Safari, peeknook.com" or a fallback.
    public var targetLabel: String {
        captureTargetLabel(appName: appName, windowTitle: windowTitle, fallback: sourceLabel)
    }
}

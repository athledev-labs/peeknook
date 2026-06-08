// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct CaptureResult: Sendable, Equatable, Codable {
    /// Optional selected text (Accessibility), supplements the screenshot for the model.
    public var text: String?
    /// Capture *modality* summary, e.g. "Vision + selected text".
    public var sourceLabel: String
    /// Owning app of the captured window, e.g. "Safari", preview trust.
    public var appName: String?
    /// Captured window title, e.g. "peeknook.com", preview trust.
    public var windowTitle: String?
    /// JPEG base64 for multimodal models (Gemma 4, etc.).
    public var screenshotBase64: String?

    public var hasVision: Bool { screenshotBase64 != nil }

    public init(
        text: String?,
        sourceLabel: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshotBase64: String? = nil
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLabel = sourceLabel
        self.appName = appName.normalizedNonEmpty
        self.windowTitle = windowTitle.normalizedNonEmpty
        self.screenshotBase64 = screenshotBase64
    }

    /// *Which* window the model will see, the line the user must be able to trust.
    /// "Safari, peeknook.com", "Safari", or the modality label as a last resort.
    public var targetLabel: String {
        captureTargetLabel(appName: appName, windowTitle: windowTitle, fallback: sourceLabel)
    }

    /// Real captured text (selection) for the preview, or "", the UI hides it when empty
    /// rather than showing filler.
    public var previewExcerpt: String {
        guard let text, !text.isEmpty else { return "" }
        return String(text.prefix(280))
    }
}

/// Shared "which window?" label used by both `CaptureResult` and `CapturePreview`
/// so the trust line never drifts between capture and preview.
func captureTargetLabel(appName: String?, windowTitle: String?, fallback: String) -> String {
    switch (appName, windowTitle) {
    case let (app?, title?): "\(app) · \(title)"
    case let (app?, nil): app
    case let (nil, title?): title
    case (nil, nil): fallback
    }
}

extension Optional where Wrapped == String {
    /// Trimmed value, or nil when missing/blank, keeps empty window titles out of the trust line.
    var normalizedNonEmpty: String? {
        guard let trimmed = self?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

public enum CaptureError: Error, Sendable, Equatable {
    case noContent
    case permissionRequired(String)
    case failed(String)
}

/// What the capture hotkey targets, both scopes are anchored on the cursor (multi-monitor aware).
public enum CaptureScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// The single window under the cursor (default, "help me with this one thing").
    case window
    /// The whole display the cursor is on ("what's going on across my screen").
    case display

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .window: "Window under cursor"
        case .display: "Whole screen"
        }
    }

    /// Short label for the home command bar.
    public var barLabel: String {
        switch self {
        case .window: "Window"
        case .display: "Screen"
        }
    }

    /// Explanatory subtitle for menus and Settings.
    public var menuDetail: String {
        switch self {
        case .window: "One window at your cursor"
        case .display: "Full display at your cursor"
        }
    }

    public var settingsIcon: String {
        switch self {
        case .window: "macwindow"
        case .display: "display"
        }
    }
}

public enum AnswerDepth: String, CaseIterable, Sendable {
    case quick
    case deep

    public var barLabel: String {
        switch self {
        case .quick: "Quick"
        case .deep: "Deep"
        }
    }

    public var menuDetail: String {
        switch self {
        case .quick: "2–3 line answers, faster"
        case .deep: "Full answers"
        }
    }

    public var settingsIcon: String {
        switch self {
        case .quick: "hare"
        case .deep: "tortoise"
        }
    }

    public init(quickMode: Bool) {
        self = quickMode ? .quick : .deep
    }

    public var quickMode: Bool { self == .quick }
}

/// How many screenshots ride as vision payloads in Ollama requests. UI and archive keep all
/// captures; this only bounds inference replay (suggestions always send zero images).
public enum InferenceImageReplay: String, Codable, Sendable, CaseIterable, Identifiable {
    case latestOnly
    case lastTwo
    case allInThread

    public var id: String { rawValue }

    public var maxImagePayloads: Int {
        switch self {
        case .latestOnly: return 1
        case .lastTwo: return 2
        case .allInThread: return Int.max
        }
    }

    public var displayName: String {
        switch self {
        case .latestOnly: "Latest only"
        case .lastTwo: "Latest two"
        case .allInThread: "All in chat"
        }
    }

    public var menuDetail: String {
        switch self {
        case .latestOnly: "One screenshot per request (default)"
        case .lastTwo: "Two most recent screenshots"
        case .allInThread: "Every screenshot in the thread"
        }
    }

    public var barLabel: String {
        switch self {
        case .latestOnly: "1 image"
        case .lastTwo: "2 images"
        case .allInThread: "All"
        }
    }

    public var settingsIcon: String {
        switch self {
        case .latestOnly: "photo"
        case .lastTwo: "photo.on.rectangle"
        case .allInThread: "photo.stack"
        }
    }
}

public protocol CaptureProviding: Sendable {
    /// - Parameter quick: capture at lower fidelity (smaller image) to cut vision-prefill
    ///   latency, the dominant cost of local inference.
    func capture(scope: CaptureScope, quick: Bool) async throws -> CaptureResult
}

// MARK: - Test-only stub

public struct StubCaptureProvider: CaptureProviding, Sendable {
    public var sampleText: String
    public var sourceLabel: String
    public var appName: String?
    public var windowTitle: String?
    /// When set, capture awaits this long before returning (for cancellation tests).
    public var captureDelayNanoseconds: UInt64?
    public var screenshotBase64: String?

    public init(
        sampleText: String,
        sourceLabel: String = "Test capture",
        appName: String? = nil,
        windowTitle: String? = nil,
        captureDelayNanoseconds: UInt64? = nil,
        screenshotBase64: String? = "stub-screenshot"
    ) {
        self.sampleText = sampleText
        self.sourceLabel = sourceLabel
        self.appName = appName
        self.windowTitle = windowTitle
        self.captureDelayNanoseconds = captureDelayNanoseconds
        self.screenshotBase64 = screenshotBase64
    }

    public func capture(scope: CaptureScope, quick: Bool) async throws -> CaptureResult {
        _ = (scope, quick)
        if let captureDelayNanoseconds {
            try await Task.sleep(nanoseconds: captureDelayNanoseconds)
            try Task.checkCancellation()
        }
        let trimmed = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptureError.noContent }
        return CaptureResult(
            text: trimmed,
            sourceLabel: sourceLabel,
            appName: appName,
            windowTitle: windowTitle,
            screenshotBase64: screenshotBase64
        )
    }
}

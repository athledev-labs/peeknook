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
    /// JPEG base64 for multimodal models (Gemma 4, etc.). Cleared once a ``screenshotBlobID`` is set.
    public var screenshotBase64: String?
    /// On-disk blob reference under the conversation archive's `blobs/` folder.
    public var screenshotBlobID: UUID?

    public var hasVision: Bool { screenshotBase64 != nil || screenshotBlobID != nil }

    public init(
        text: String?,
        sourceLabel: String,
        appName: String? = nil,
        windowTitle: String? = nil,
        screenshotBase64: String? = nil,
        screenshotBlobID: UUID? = nil
    ) {
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLabel = sourceLabel
        self.appName = appName.normalizedNonEmpty
        self.windowTitle = windowTitle.normalizedNonEmpty
        self.screenshotBase64 = screenshotBase64
        self.screenshotBlobID = screenshotBlobID
    }

    private enum CodingKeys: String, CodingKey {
        case text, sourceLabel, appName, windowTitle, screenshotBase64, screenshotBlobID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.sourceLabel = try container.decode(String.self, forKey: .sourceLabel)
        self.appName = try container.decodeIfPresent(String.self, forKey: .appName).normalizedNonEmpty
        self.windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle).normalizedNonEmpty
        self.screenshotBase64 = try container.decodeIfPresent(String.self, forKey: .screenshotBase64)
        self.screenshotBlobID = try container.decodeIfPresent(UUID.self, forKey: .screenshotBlobID)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encode(sourceLabel, forKey: .sourceLabel)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(screenshotBlobID, forKey: .screenshotBlobID)
        if screenshotBlobID == nil {
            try container.encodeIfPresent(screenshotBase64, forKey: .screenshotBase64)
        }
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
    /// Minimal valid JPEG bytes so blob externalization and vision stubs round-trip in tests.
    public static let defaultScreenshotBase64 = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()

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
        screenshotBase64: String? = StubCaptureProvider.defaultScreenshotBase64
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

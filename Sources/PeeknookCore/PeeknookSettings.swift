// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Product preferences under the `peeknook.*` namespace (never `opennook.*`).
public struct PeeknookSettings: Codable, Equatable, Sendable {
    public static let defaultsKey = "peeknook.settings.v1"

    public var mode: PracticeMode
    public var previewBeforeInfer: Bool
    public var ollamaBaseURL: String
    public var textModel: String
    /// Faster, terser answers: caps output length and asks the model for 2–3 lines.
    public var quickMode: Bool
    /// Window under the cursor vs the whole display under the cursor.
    public var captureScope: CaptureScope
    /// Ask the model to propose 2–3 next questions after each answer (the dynamic action pills).
    public var suggestFollowUps: Bool
    /// Global capture shortcut (default ⌘⇧P).
    public var captureHotkey: CaptureHotkey

    public init(
        mode: PracticeMode = .general,
        previewBeforeInfer: Bool = false,
        ollamaBaseURL: String = "http://127.0.0.1:11434",
        textModel: String = SystemProfile.current().suggestedTextModel,
        quickMode: Bool = false,
        captureScope: CaptureScope = .window,
        suggestFollowUps: Bool = true,
        captureHotkey: CaptureHotkey = .default
    ) {
        self.mode = mode
        self.previewBeforeInfer = previewBeforeInfer
        self.ollamaBaseURL = ollamaBaseURL
        self.textModel = textModel
        self.quickMode = quickMode
        self.captureScope = captureScope
        self.suggestFollowUps = suggestFollowUps
        self.captureHotkey = captureHotkey
    }

    private enum CodingKeys: String, CodingKey {
        case mode, previewBeforeInfer, ollamaBaseURL, textModel, quickMode, captureScope, suggestFollowUps, captureHotkey
    }

    // Tolerant decode — a saved blob missing a newer key keeps the rest of the user's
    // settings instead of resetting everything to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decodeIfPresent(PracticeMode.self, forKey: .mode) ?? .general
        self.previewBeforeInfer = try c.decodeIfPresent(Bool.self, forKey: .previewBeforeInfer) ?? false
        self.ollamaBaseURL = try c.decodeIfPresent(String.self, forKey: .ollamaBaseURL) ?? "http://127.0.0.1:11434"
        self.textModel = try c.decodeIfPresent(String.self, forKey: .textModel)
            ?? SystemProfile.current().suggestedTextModel
        self.quickMode = try c.decodeIfPresent(Bool.self, forKey: .quickMode) ?? false
        self.captureScope = try c.decodeIfPresent(CaptureScope.self, forKey: .captureScope) ?? .window
        self.suggestFollowUps = try c.decodeIfPresent(Bool.self, forKey: .suggestFollowUps) ?? true
        self.captureHotkey = try c.decodeIfPresent(CaptureHotkey.self, forKey: .captureHotkey) ?? .default
    }

    public static let `default` = PeeknookSettings(
        textModel: SystemProfile.current().suggestedTextModel
    )

    public static func load(from defaults: UserDefaults) -> PeeknookSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              var settings = try? JSONDecoder().decode(PeeknookSettings.self, from: data)
        else { return .default }
        if !PracticeMode.shipped.contains(settings.mode) {
            settings.mode = PracticeMode.shipped[0]
        }
        return settings
    }

    public func save(to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

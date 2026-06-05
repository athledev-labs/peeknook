// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A vision model Peeknook can run — today via Ollama; extend this list as backends ship.
public struct InferenceModelOption: Identifiable, Equatable, Sendable {
    public var id: String { tag }

    /// Backend identifier (Ollama tag today).
    public let tag: String
    public let displayName: String
    public let provider: String
    public let downloadHint: String?
    public let supportsVision: Bool

    public init(
        tag: String,
        displayName: String,
        provider: String,
        downloadHint: String? = nil,
        supportsVision: Bool = true
    ) {
        self.tag = tag
        self.displayName = displayName
        self.provider = provider
        self.downloadHint = downloadHint
        self.supportsVision = supportsVision
    }

    /// Secondary line in the model picker menu.
    public var menuDetail: String {
        var parts = [tag, provider]
        if let downloadHint { parts.append(downloadHint) }
        return parts.joined(separator: " · ")
    }
}

public enum TextModelCatalog {
    /// Curated models shown in the home picker. Add entries here when a new backend ships.
    public static let offered: [InferenceModelOption] = [
        InferenceModelOption(
            tag: "gemma4:e2b",
            displayName: "Gemma 4 E2B",
            provider: "Ollama",
            downloadHint: "~7 GB"
        ),
        InferenceModelOption(
            tag: "gemma4:e4b",
            displayName: "Gemma 4 E4B",
            provider: "Ollama",
            downloadHint: "~10 GB"
        ),
        InferenceModelOption(
            tag: "gemma4:26b",
            displayName: "Gemma 4 26B",
            provider: "Ollama",
            downloadHint: "~18 GB"
        ),
    ]

    public static func option(for tag: String) -> InferenceModelOption? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        return offered.first { OllamaSetupClient.matchesModel(installedNames: [$0.tag], wanted: normalized) }
            ?? offered.first { $0.tag == normalized }
    }

    public static func displayName(for tag: String) -> String {
        option(for: tag)?.displayName ?? tag
    }

    /// @deprecated Use ``displayName(for:)`` — kept for tests migrating off short tags.
    public static func shortLabel(for model: String) -> String {
        displayName(for: model)
    }
}

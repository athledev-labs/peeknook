// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A vision model Peeknook can run, today via Ollama; extend this list as backends ship.
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

    /// Subtitle on the Settings download row.
    public var downloadRowSubtitle: String {
        if let downloadHint {
            return "\(downloadHint) model file · once via \(provider)"
        }
        return "Large model file · once via \(provider)"
    }

    /// Body copy for the download confirmation dialog.
    public var downloadConfirmationMessage: String {
        let size = downloadHint ?? "a large download"
        return "\(size) model file via \(provider). Peek won't capture until it's on your Mac."
    }

    /// Build an option from a user-added model so custom tags flow through the same picker,
    /// download, and selection paths as curated ones.
    public init(custom entry: CustomModelEntry) {
        self.init(
            tag: entry.tag,
            displayName: entry.resolvedDisplayName,
            provider: "Ollama",
            downloadHint: nil
        )
    }
}

/// A model the user added by hand (any Ollama tag). Persisted in ``PeeknookSettings`` so
/// "bring your own model" survives a relaunch. Vision support is detected live from Ollama
/// (`/api/show` capabilities), not stored, so it can't go stale.
public struct CustomModelEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String { tag }
    public let tag: String
    /// Optional friendly label; falls back to the tag.
    public let displayName: String?

    public init(tag: String, displayName: String? = nil) {
        self.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.displayName = (trimmedName?.isEmpty == false) ? trimmedName : nil
    }

    public var resolvedDisplayName: String {
        displayName ?? tag
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
        InferenceModelOption(
            tag: "gemma4:31b",
            displayName: "Gemma 4 31B",
            provider: "Ollama",
            downloadHint: "~20 GB"
        ),
    ]

    /// Curated models plus any the user added by hand, deduped by tag (curated wins). This is the
    /// list the picker should show so "bring your own model" appears alongside the built-ins.
    public static func merged(custom: [CustomModelEntry]) -> [InferenceModelOption] {
        var result = offered
        var seen = Set(offered.map { OllamaSetupClient.normalizedTag($0.tag) })
        for entry in custom {
            let key = OllamaSetupClient.normalizedTag(entry.tag)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(InferenceModelOption(custom: entry))
        }
        return result
    }

    public static func option(for tag: String, custom: [CustomModelEntry] = []) -> InferenceModelOption? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let pool = custom.isEmpty ? offered : merged(custom: custom)
        return pool.first { OllamaSetupClient.matchesModel(installedNames: [$0.tag], wanted: normalized) }
            ?? pool.first { $0.tag == normalized }
    }

    public static func displayName(for tag: String, custom: [CustomModelEntry] = []) -> String {
        option(for: tag, custom: custom)?.displayName ?? tag
    }

    /// @deprecated Use ``displayName(for:)``, kept for tests migrating off short tags.
    public static func shortLabel(for model: String) -> String {
        displayName(for: model)
    }
}

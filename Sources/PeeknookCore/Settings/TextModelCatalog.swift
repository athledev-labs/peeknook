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
    /// One plain-language line on what this model is good (and not good) at, for the picker subtitle.
    /// File size tells a general user nothing about whether a model will misread their screenshot,
    /// so curated tiers carry this instead. Nil for custom tags (no claim we can stand behind).
    public let capabilitySummary: String?
    /// The minimum total RAM (GB) at which this model is a sensible auto-suggested default — the model
    /// is gated to more RAM precisely because its resident working set is larger. ``recommendedTag``
    /// picks the highest-floor model a Mac can afford. `nil` means manual-only: a user can still
    /// select it, but it is never auto-recommended (custom tags, or a tier we don't push by default).
    public let recommendedRAMFloorGB: Int?

    public init(
        tag: String,
        displayName: String,
        provider: String,
        downloadHint: String? = nil,
        supportsVision: Bool = true,
        capabilitySummary: String? = nil,
        recommendedRAMFloorGB: Int? = nil
    ) {
        self.tag = tag
        self.displayName = displayName
        self.provider = provider
        self.downloadHint = downloadHint
        self.supportsVision = supportsVision
        self.capabilitySummary = capabilitySummary
        self.recommendedRAMFloorGB = recommendedRAMFloorGB
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

    /// Estimated download size in bytes, derived from `downloadHint` (no new source of truth). Nil for
    /// custom tags with no hint — the disk pre-check skips when the size is unknown.
    public var estimatedDownloadBytes: Int64? {
        ByteFormat.bytes(fromGigabytesHint: downloadHint)
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
    /// Curated models shown in the home picker, ordered smallest→largest by download size. Add
    /// entries here when a new backend ships. Note the families are interleaved by size, not grouped:
    /// Qwen2.5-VL 7B is a smaller download than Gemma 4 E2B yet reads detailed screens better, which
    /// is exactly why it is the suggested default for most Macs (see ``SystemProfile``).
    public static let offered: [InferenceModelOption] = [
        InferenceModelOption(
            tag: "qwen2.5vl:7b",
            displayName: "Qwen2.5-VL 7B",
            provider: "Ollama",
            downloadHint: "~6 GB",
            capabilitySummary: "Sharp at reading detailed screens (charts, tables, documents); fits most Macs.",
            recommendedRAMFloorGB: 16
        ),
        InferenceModelOption(
            tag: "gemma4:e2b",
            displayName: "Gemma 4 E2B",
            provider: "Ollama",
            downloadHint: "~7 GB",
            capabilitySummary: "Fastest, lightest. Great for text, code & quick questions; may misread detailed images (charts, tables, game boards).",
            recommendedRAMFloorGB: 0
        ),
        InferenceModelOption(
            tag: "gemma4:e4b",
            displayName: "Gemma 4 E4B",
            provider: "Ollama",
            downloadHint: "~10 GB",
            capabilitySummary: "Balanced; reads most screens accurately.",
            recommendedRAMFloorGB: 32
        ),
        InferenceModelOption(
            tag: "gemma4:26b",
            displayName: "Gemma 4 26B",
            provider: "Ollama",
            downloadHint: "~18 GB",
            capabilitySummary: "Most accurate at detailed images; needs lots of memory.",
            recommendedRAMFloorGB: 48
        ),
        InferenceModelOption(
            tag: "gemma4:31b",
            displayName: "Gemma 4 31B",
            provider: "Ollama",
            downloadHint: "~20 GB",
            capabilitySummary: "Most accurate at detailed images; needs lots of memory."
            // recommendedRAMFloorGB left nil: manual-only. 26b already covers the high-RAM tier, so
            // 31b is a power-user pick the picker still offers but the default policy never auto-suggests.
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

    /// The curated tag to auto-suggest for a Mac with this much RAM: the most capable model the Mac can
    /// afford, where capability is read off ``InferenceModelOption/recommendedRAMFloorGB`` (a model is
    /// gated to more RAM precisely because it is heavier). Picks the highest floor that is ≤ `gb`;
    /// models with a nil floor are manual-only and never returned. This is the single home of the
    /// RAM→model policy, driven entirely by the catalog: adding or re-tiering a model is one edit to
    /// ``offered``, with no parallel `if gb < N` ladder to keep in sync. ``SystemProfile`` delegates here.
    public static func recommendedTag(forPhysicalMemoryGB gb: Int) -> String {
        let affordable = offered.compactMap { option -> (tag: String, floor: Int)? in
            guard let floor = option.recommendedRAMFloorGB, floor <= gb else { return nil }
            return (option.tag, floor)
        }
        if let best = affordable.max(by: { $0.floor < $1.floor }) {
            return best.tag
        }
        // No floored model fits (only if every floor exceeds `gb`). Fall back to the lowest-floor
        // curated model so we always return something the user can install, never an empty string.
        return offered
            .compactMap { o in o.recommendedRAMFloorGB.map { (o.tag, $0) } }
            .min(by: { $0.1 < $1.1 })?.0
            ?? offered.first?.tag
            ?? "gemma4:e2b"
    }

    /// The next-smaller curated tier **in the same model family** (`offered` is ordered
    /// smallest→largest), or nil for the smallest tier in that family, a tag not in the catalog, or a
    /// custom tag. Lets the download confirmation offer a lighter, faster alternative before a user
    /// commits to a larger pull. Scoped to one family on purpose: across families the smaller-by-bytes
    /// model can be the *more* capable one (Qwen2.5-VL 7B is a smaller download than Gemma 4 E2B yet
    /// reads screens better), so the "a faster, lighter option" framing only holds within a family.
    public static func leanerAlternative(to option: InferenceModelOption) -> InferenceModelOption? {
        guard let index = offered.firstIndex(where: {
            OllamaSetupClient.normalizedTag($0.tag) == OllamaSetupClient.normalizedTag(option.tag)
        }) else { return nil }
        let targetFamily = modelFamily(option.tag)
        for i in stride(from: index - 1, through: 0, by: -1) where modelFamily(offered[i].tag) == targetFamily {
            return offered[i]
        }
        return nil
    }

    /// The repository name before the tag (`gemma4:e2b` → `gemma4`, `qwen2.5vl:7b` → `qwen2.5vl`),
    /// used to keep ``leanerAlternative`` within a single family's size ladder.
    static func modelFamily(_ tag: String) -> Substring {
        OllamaSetupClient.normalizedTag(tag).prefix { $0 != ":" }
    }

    /// @deprecated Use ``displayName(for:)``, kept for tests migrating off short tags.
    public static func shortLabel(for model: String) -> String {
        displayName(for: model)
    }
}

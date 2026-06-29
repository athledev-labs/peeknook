// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Per-profile output shaping, expressed as DATA — never a behavior name (invariant 1). Today it
/// carries only the translation languages; it is a sub-struct so a future output setting (formality,
/// glossary) lands inside it without ever adding another top-level ``GroundProfile`` key. The values
/// are free-text language labels (e.g. "Japanese", "ja", "Brazilian Portuguese"): the model reads them
/// directly, so strict BCP-47 validation would only reject things the model handles fine. The single
/// real guard is a tight length cap against a paste-bomb. Sanitized (trim + cap + empty->nil) at BOTH
/// boundaries — decode and the ``ProfileStore`` setter — like every other profile free-text field.
public struct ProfileOutputConfig: Equatable, Sendable {
    /// Long enough for any language label, short enough that the field can't crowd the prompt.
    public static let maxLanguageLength = 64

    /// The language the captured text is in. Nil = let the model auto-detect.
    public var sourceLanguage: String?
    /// The language to translate the captured text into. Nil = no translation.
    public var targetLanguage: String?
    /// Per-profile opt-in to let a CAPTION session translate over a remote / `:cloud` route. Default
    /// false: captions are local-only by default because audio is conversational-PII-dense and the
    /// screen-secret redactor does not cover it. Distinct from the global remote toggle and from the
    /// translate target — enabling translation never implies remote egress. Meaningless without a target
    /// language (a caption needs one), so ``sanitized`` zeroes it when `targetLanguage` is nil.
    public var captionAllowRemote: Bool

    public init(sourceLanguage: String? = nil, targetLanguage: String? = nil, captionAllowRemote: Bool = false) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.captionAllowRemote = captionAllowRemote
    }

    /// Trim + cap each language field (empty/whitespace becomes nil); drop a caption opt-in that has no
    /// target language to attach to.
    public var sanitized: ProfileOutputConfig {
        let target = Self.sanitizedLanguage(targetLanguage)
        return ProfileOutputConfig(
            sourceLanguage: Self.sanitizedLanguage(sourceLanguage),
            targetLanguage: target,
            captionAllowRemote: target == nil ? false : captionAllowRemote   // no orphan opt-in without a target
        )
    }

    /// True when the config carries no usable value — the profile should then persist no config at all
    /// (so an emptied config never lingers as `outputConfig: {}`). Keyed on the directive, not on raw
    /// field presence: a source language WITHOUT a target produces no ``translationDirective`` (a source
    /// alone is not a translate request), so it must not keep the config alive — otherwise an orphan
    /// `{sourceLanguage}` lingers in storage and resurfaces as an unexpected "from X" clause later.
    public var isEmpty: Bool {
        translationDirective == nil
    }

    /// The translation projection consumed by the prompt builder: a directive exists iff a target
    /// language is set (the source is optional). Keyed on the PRESENCE of data, never on its value.
    public var translationDirective: TranslationDirective? {
        let s = sanitized
        guard let target = s.targetLanguage else { return nil }
        return TranslationDirective(targetLanguage: target, sourceLanguage: s.sourceLanguage)
    }

    static func sanitizedLanguage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // Collapse EVERY run of whitespace/newlines (interior included) to a single space, then cap. A
        // language label is single-line free text, so this preserves a real value ("Brazilian Portuguese"
        // round-trips) while removing the one way an imported preset could inject a structural `## section`:
        // the label is interpolated RAW and UNFENCED into the user-message Task line (unlike the fenced
        // instruction/template), so an interior newline would otherwise start a new markdown line.
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLanguageLength))
    }
}

// MARK: - Tolerant Codable (per-field shielded, like the rest of the profile)

extension ProfileOutputConfig: Codable {
    private enum CodingKeys: String, CodingKey { case sourceLanguage, targetLanguage, captionAllowRemote }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Per-field `try?` shielding: a malformed field (e.g. a number where a string is expected)
        // degrades to nil WITHOUT taking its valid sibling down with it. The synthesized Codable would
        // throw the whole struct on one bad field, and ``GroundProfile``'s outer `try?` would then drop
        // both — the [String: V] throw-trap this codebase has been bitten by before.
        let source = ((try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)) ?? nil)
        let target = ((try? c.decodeIfPresent(String.self, forKey: .targetLanguage)) ?? nil)
        let allowRemote = ((try? c.decodeIfPresent(Bool.self, forKey: .captionAllowRemote)) ?? nil) ?? false
        self.sourceLanguage = Self.sanitizedLanguage(source)
        self.targetLanguage = Self.sanitizedLanguage(target)
        // Drop an orphan opt-in (a flag with no target language can't mean anything), mirroring `sanitized`.
        self.captionAllowRemote = (self.targetLanguage != nil) && allowRemote
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        // Encode only when true, so a default config stays byte-identical (the key never appears).
        if captionAllowRemote { try c.encode(true, forKey: .captionAllowRemote) }
    }
}

/// A request to translate this turn's captured text, projected from ``ProfileOutputConfig`` at
/// request-build time. Deliberately NOT Codable: like ``RoleResolution`` and ``InferenceEndpoint`` it
/// is a transient routing/prompt value rebuilt per turn, so it can never reach UserDefaults. It is
/// data, not a mode — the prompt builder interpolates `targetLanguage` into the task line; nothing ever
/// branches on its value.
public struct TranslationDirective: Sendable, Equatable {
    /// Non-empty, sanitized language label.
    public let targetLanguage: String
    /// Nil = auto-detect the source language.
    public let sourceLanguage: String?

    public init(targetLanguage: String, sourceLanguage: String? = nil) {
        self.targetLanguage = targetLanguage
        self.sourceLanguage = sourceLanguage
    }
}

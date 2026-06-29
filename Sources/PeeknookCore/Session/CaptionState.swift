// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The transient, replace-in-place subtitle state the caption surface renders. Held on the
/// ``SessionOrchestrator`` facade as `liveCaption` — the analogue of `activeCameraSession` for the
/// `.captioning` surface. Deliberately **NOT** `Codable` and never archived: a caption is ephemeral by
/// construction, so no transcript can reach the conversation store, the blob store, or the usage ledger.
/// Bounded: only the active line plus a short rolling tail are retained, so an idle surface holds no
/// growing transcript.
public struct CaptionState: Sendable, Equatable {
    /// The segment currently streaming a translation (replaced in place as tokens arrive).
    public var currentLine: String
    /// The source-language interim hypothesis ("hearing…" cue), cleared when a segment finalizes.
    public var hearingPartial: String
    /// The last few finalized translated lines, oldest first, capped at ``maxRecentLines``.
    public var recentLines: [String]
    /// True while a finalized segment is being translated (drives a subtle in-progress affordance).
    public var isTranslating: Bool
    /// Human label for the source language (nil = auto), for the surface header.
    public var sourceLabel: String?
    /// Human label for the target language, for the surface header.
    public var targetLabel: String
    /// Non-nil ONLY when the user opted a profile into remote caption egress — the distinct
    /// "sending to <host>" indicator derives from it. Nil = local-only (the default).
    public var remoteEgressHost: String?

    /// The rolling tail cap — small on purpose, so the surface stays a glance, never a transcript.
    public static let maxRecentLines = 3

    public init(
        currentLine: String = "",
        hearingPartial: String = "",
        recentLines: [String] = [],
        isTranslating: Bool = false,
        sourceLabel: String? = nil,
        targetLabel: String = "",
        remoteEgressHost: String? = nil
    ) {
        self.currentLine = currentLine
        self.hearingPartial = hearingPartial
        self.recentLines = recentLines
        self.isTranslating = isTranslating
        self.sourceLabel = sourceLabel
        self.targetLabel = targetLabel
        self.remoteEgressHost = remoteEgressHost
    }

    /// Push the finished `currentLine` into the rolling tail (capped) and clear it. A blank line is
    /// dropped rather than recorded, so an empty translation never pollutes the tail.
    public mutating func commitCurrentLine() {
        let trimmed = currentLine.trimmingCharacters(in: .whitespacesAndNewlines)
        currentLine = ""
        guard !trimmed.isEmpty else { return }
        recentLines.append(trimmed)
        if recentLines.count > Self.maxRecentLines {
            recentLines.removeFirst(recentLines.count - Self.maxRecentLines)
        }
    }
}

/// Mandatory bounds for the caption surface. These are NOT user-disable-able: a continuous audio tap
/// must always be bounded. Tunable constants (revisit with product), not settings.
public enum CaptionPolicy: Sendable {
    /// The hard auto-disarm cap — a caption session disarms this long after it was armed, regardless of
    /// activity (audio is not user interaction, so it never resets the countdown). The user can re-arm.
    public static let maxArmedSeconds: TimeInterval = 600
    /// Disarm after this long with no finalized segment (the audio source went away). A UX convenience,
    /// not the load-bearing bound — the mandatory cap is.
    public static let silenceTimeout: TimeInterval = 120
}

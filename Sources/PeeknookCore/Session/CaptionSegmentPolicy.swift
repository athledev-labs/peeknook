// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free decision for when a streaming transcript's interim text has stabilized enough to
/// finalize as a caption segment (and fire one translate pass). A sibling of ``LiveRefreshPolicy``: all
/// timing is injected, so the cadence is unit-testable apart from the device-only audio tap.
///
/// A segment finalizes when the recognizer marks it final, OR the interim has been quiet for
/// ``stabilityWindow`` (the speaker paused), OR it has run for ``maxSegmentAge`` (a pause-less monologue
/// still gets sliced) — all gated on the interim carrying at least ``minCharacters`` so silence and
/// stray noise never finalize an empty line.
public enum CaptionSegmentPolicy: Sendable {
    public enum Decision: Equatable, Sendable {
        case wait
        case finalize
    }

    /// Quiet time after the last interim token before the segment is considered settled.
    public static let stabilityWindow: TimeInterval = 1.2
    /// Hard cut so a continuous monologue with no pause still segments.
    public static let maxSegmentAge: TimeInterval = 6
    /// Minimum interim length to finalize — guards against finalizing silence / a stray token.
    public static let minCharacters = 2

    public static func decide(
        interim: String,
        secondsSinceLastToken: TimeInterval,
        secondsSinceSegmentStart: TimeInterval,
        recognizerMarkedFinal: Bool
    ) -> Decision {
        let trimmed = interim.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minCharacters else { return .wait }
        if recognizerMarkedFinal { return .finalize }
        if secondsSinceLastToken >= stabilityWindow { return .finalize }
        if secondsSinceSegmentStart >= maxSegmentAge { return .finalize }
        return .wait
    }
}

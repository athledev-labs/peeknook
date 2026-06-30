// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which transcript source the fusing transcriber treats as authoritative for TEXT right now.
public enum CaptionSource: Sendable, Equatable {
    /// On-screen text (subtitles / lyrics) read by the screen reader — ground truth when present.
    case screen
    /// On-device speech recognition of the system audio — the always-available fallback.
    case audio
}

/// Pure, clock-free router that decides whether on-screen text or audio transcription is authoritative.
/// The autonomy brain of the caption fuser, kept a leaf so the arbitration is tunable by data and
/// unit-testable apart from the two device-only taps it sits between.
///
/// Bias toward the screen: when a foreign show is rendering subtitles they are GROUND TRUTH, so any
/// recent screen segment claims authority. When the subtitles stop (a gap, a title card, a DRM-black
/// frame that OCR reads as nothing), authority falls back to audio so captions never stall. Hysteresis —
/// a longer release window than claim window — keeps it from flapping at the boundary between a subtitle
/// gap and the next line. `secondsSinceScreenSegment` is `.infinity` until the screen has ever produced
/// one, so a session with no on-screen text simply rides audio the whole time.
///
/// Grow-by-data: new signals (audio confidence, a recognized-song hint) become new parameters here, never
/// branches in the fuser. The fuser only owns the two taps and the clock that feeds this its seconds.
public enum CaptionSourcePolicy: Sendable {
    /// While on audio, a screen segment newer than this CLAIMS authority for the screen.
    public static let screenClaimWindow: TimeInterval = 6
    /// While on screen, authority is RELEASED back to audio only after the screen has been silent this
    /// long — deliberately longer than the claim window so a brief subtitle gap doesn't flap the source.
    public static let screenReleaseWindow: TimeInterval = 12

    /// The authoritative source given the current one and how long since the screen last produced a
    /// stable segment. Asymmetric windows give the hysteresis.
    public static func authoritativeSource(
        current: CaptionSource,
        secondsSinceScreenSegment: TimeInterval
    ) -> CaptionSource {
        switch current {
        case .screen:
            return secondsSinceScreenSegment <= screenReleaseWindow ? .screen : .audio
        case .audio:
            return secondsSinceScreenSegment <= screenClaimWindow ? .screen : .audio
        }
    }
}

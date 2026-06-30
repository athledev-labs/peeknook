// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free policy for the caption surface's audio-level meter. The DECISIONS — how raw PCM
/// energy becomes a normalized 0...1 meter reading, how that reading is smoothed (ballistics), and when
/// a change is worth pushing across the seam — all live here so they are unit-testable apart from the
/// device-only audio tap. ``RotatingSFSpeechTranscriber`` owns only the `CMSampleBuffer → [Float]`
/// extraction glue and the meter clock; every number it shows the user comes from one of these
/// functions. No fake pulse: ``normalized(meanSquare:)`` is a straight RMS → dBFS map of the measured
/// samples, so a silent tap reads 0.
///
/// The level is loudness, not content: a single scalar, never persisted, that the
/// ``CaptionState/audioLevel`` surface renders.
public enum AudioLevelMeter: Sendable {
    /// Quietest level the meter still shows. Below this dBFS the reading is 0 (the bottom of the meter),
    /// so room tone / noise floor reads as silence rather than a permanent low glow.
    public static let floorDecibels: Float = -50

    /// Rising ballistics: how fast the meter chases a LOUDER target (fraction of the gap closed per
    /// emission). Fast so speech onset is immediate.
    public static let attack: Float = 0.5
    /// Falling ballistics: how fast the meter chases a QUIETER target. Slower than attack so the meter
    /// eases down between words instead of strobing.
    public static let decay: Float = 0.2
    /// Below this normalized level the smoothed reading snaps to exactly 0, so the meter visibly rests at
    /// empty during silence (and emission can stop) rather than asymptoting forever toward zero.
    public static let restFloor: Float = 0.02
    /// Minimum normalized change worth emitting across the seam. Steady silence (0 → 0) falls under this,
    /// so an idle tap costs no main-actor hops.
    public static let perceptibleDelta: Float = 0.01

    /// Sum of the squares of `samples` (the energy term of an RMS). Zero for an empty buffer. The pure
    /// entry point the extraction glue accumulates over a meter window.
    public static func sumOfSquares(_ samples: [Float]) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return sum
    }

    /// Map a window's mean-square energy to a normalized 0...1 level: RMS = sqrt(meanSquare), expressed
    /// in dBFS (full-scale 1.0 = 0 dB), then linearly mapped from ``floorDecibels``...0 dB onto 0...1 and
    /// clamped. A non-positive mean-square (silence) is 0.
    public static func normalized(meanSquare: Float) -> Float {
        guard meanSquare > 0 else { return 0 }
        let rms = sqrt(meanSquare)
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        guard decibels > floorDecibels else { return 0 }
        let normalized = (decibels - floorDecibels) / -floorDecibels
        return min(max(normalized, 0), 1)
    }

    /// Asymmetric smoothing toward `target`: close the gap by ``attack`` when rising and ``decay`` when
    /// falling, clamp to 0...1, and snap to 0 once the result drops under ``restFloor`` so the meter
    /// settles cleanly at empty.
    public static func smoothed(previous: Float, target: Float) -> Float {
        let coefficient = target > previous ? attack : decay
        let next = previous + (target - previous) * coefficient
        let clamped = min(max(next, 0), 1)
        return clamped < restFloor ? 0 : clamped
    }

    /// Whether `next` differs from `previous` enough to be worth emitting. Gates redundant updates so a
    /// silent (0 → 0) or barely-moving meter never floods the consumer.
    public static func isPerceptibleChange(from previous: Float, to next: Float) -> Bool {
        abs(next - previous) >= perceptibleDelta
    }
}

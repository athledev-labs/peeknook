// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free policy that distills one ``ScreenTextSnapshot`` into the single best CAPTION
/// candidate — the text most likely to be the live subtitle / lyric on screen right now. This is the
/// spatial half of the screen-read decision (the temporal "has it settled into a new line" half lives in
/// ``ScreenTextSegmentPolicy``), kept here as a deterministic leaf so the heuristic is tunable by data
/// and unit-testable apart from the device-only read.
///
/// Two strategies, picked by what the snapshot carries:
///  - **Geometry (OCR).** Subtitles render large, low, and roughly centered; UI chrome is small and at
///    the edges. So a line is scored by font size (rect height), how far into the lower "subtitle zone"
///    it sits, and its OCR confidence. The top-scoring band of lines (up to ``maxLines``) is returned in
///    reading order. This is the workhorse for video shows.
///  - **Structure (accessibility).** No pixels, so no geometry: fall back to the longest confident lines
///    (a caption is a sentence; chrome labels are short words). Weaker than OCR by nature — the composite
///    reader treats a thin accessibility result as a reason to escalate to OCR.
///
/// Never fabricates: an empty/low-signal snapshot yields `nil` (the surface shows its honest "listening"
/// placeholder), never a guess.
public enum OnScreenLineExtractor: Sendable {
    /// Lines whose vertical center sits at or below this fraction of the frame get the subtitle-zone
    /// boost. Subtitles overwhelmingly render in the lower portion; this is a soft preference (edge text
    /// still scores on size + confidence), not a hard crop.
    public static let subtitleZoneTop: Float = 0.45
    /// Multiplier applied to a line's score when it sits in the subtitle zone.
    public static let zoneBoost: Float = 2.0
    /// Drop OCR lines below this confidence as noise so flicker/garbage never becomes a caption.
    public static let minConfidence: Float = 0.3
    /// A caption is a glance: keep at most this many lines so a text-dense frame can't dump a wall.
    public static let maxLines = 3
    /// A kept line must be at least this close (as a fraction of the top score) to the best line to join
    /// it — so a single salient subtitle isn't padded with unrelated chrome that happened to rank next.
    public static let bandFraction: Float = 0.5

    /// The best caption candidate in `snapshot`, or `nil` when there is no usable text.
    public static func caption(from snapshot: ScreenTextSnapshot) -> String? {
        let usable = snapshot.lines.filter { line in
            !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && line.confidence >= minConfidence
        }
        guard !usable.isEmpty else { return nil }

        let scored = usable.map { (line: $0, score: salience($0)) }
        guard let topScore = scored.map(\.score).max(), topScore > 0 else { return nil }

        // GEOMETRY (OCR): a subtitle can wrap across stacked lines, so join the salient band in reading
        // order. STRUCTURE (accessibility, no rects): a real caption is ONE substantial text node, so
        // take only the single best line — never concatenate separate UI labels into a fake caption.
        let hasGeometry = usable.contains { $0.rect != nil }
        if !hasGeometry {
            let best = scored.max { $0.score < $1.score }?.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (best?.isEmpty == false) ? best : nil
        }

        let threshold = topScore * bandFraction
        let kept = scored
            .filter { $0.score >= threshold }
            .sorted { ($0.line.rect?.midY ?? .greatestFiniteMagnitude) < ($1.line.rect?.midY ?? .greatestFiniteMagnitude) }
            .prefix(maxLines)
            .map { $0.line.text.trimmingCharacters(in: .whitespacesAndNewlines) }

        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Salience of one line. With geometry: font size × subtitle-zone boost × confidence. Without:
    /// length × confidence (a caption is a sentence). Always non-negative.
    static func salience(_ line: ScreenTextLine) -> Float {
        let confidence = max(0, min(1, line.confidence))
        guard let rect = line.rect else {
            let length = Float(line.text.trimmingCharacters(in: .whitespacesAndNewlines).count)
            return length * confidence
        }
        let size = max(0, rect.height)
        let zone = rect.midY >= subtitleZoneTop ? zoneBoost : 1
        return size * zone * confidence
    }
}

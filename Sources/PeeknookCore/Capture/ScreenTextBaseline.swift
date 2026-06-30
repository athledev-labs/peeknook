// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure, clock-free policy that separates LIVE on-screen text from static page CHROME. The screen reader
/// freezes a whole window (a browser tab, a player) and OCRs everything in it — including furniture that
/// is NOT a caption: the video title, the channel name, a "Share" button, sidebar items. Those are
/// present the instant captioning arms and they never change; a real subtitle/lyric APPEARS afterward and
/// is swapped out as the show plays.
///
/// So the rule is "ignore whatever text was already on screen at arm". The caller snapshots a
/// ``signature`` of the first read and, on every later read, ``filtered`` drops any line whose text
/// matches that baseline before the spatial ``OnScreenLineExtractor`` ever sees it. The result: a static
/// page (a song with no subtitles) emits NOTHING from the screen and the caption rides the audio path;
/// only text that wasn't there at arm can become a caption.
///
/// Normalization is shared with ``ScreenTextSegmentPolicy`` (case- and whitespace-insensitive) so the
/// same OCR re-spacing/capitalization wobble that doesn't read as a new subtitle also doesn't let chrome
/// slip past the baseline. A leaf with no clock and no device handle, so it is tunable by data and
/// unit-testable apart from the read.
public enum ScreenTextBaseline: Sendable {
    /// The normalized set of non-empty lines present in a read — the chrome fingerprint captured at arm.
    public static func signature(of lines: [ScreenTextLine]) -> Set<String> {
        var result: Set<String> = []
        for line in lines {
            let normalized = ScreenTextSegmentPolicy.normalized(line.text)
            if !normalized.isEmpty { result.insert(normalized) }
        }
        return result
    }

    /// Drop every line whose normalized text is in `baseline` (static chrome captured at arm). Lines that
    /// appeared after arm — the actual subtitles — pass through untouched. An empty baseline is a no-op.
    public static func filtered(_ lines: [ScreenTextLine], excluding baseline: Set<String>) -> [ScreenTextLine] {
        guard !baseline.isEmpty else { return lines }
        return lines.filter { !baseline.contains(ScreenTextSegmentPolicy.normalized($0.text)) }
    }
}

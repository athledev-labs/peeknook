// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Shared answer cleanup for display and on-device speech so TTS tracks what the user sees.
public enum AnswerDisplayText {
    public static func sanitizedForDisplay(_ text: String) -> String {
        var output = text
        let patterns: [(String, String)] = [
            (#"\$\s*\\text\{([^}]*)\}\s*\$"#, "$1"),
            (#"\$\s*([^$]+?)\s*\$"#, "$1"),
            (#"\\text\{([^}]*)\}"#, "$1"),
        ]
        for (pattern, template) in patterns {
            output = output.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }
        return output
    }

    public static func plainForSpeech(_ text: String) -> String {
        sanitizedForDisplay(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

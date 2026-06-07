// SPDX-License-Identifier: Apache-2.0

import Foundation

/// On-device signals for Settings → System & usage (no network).
public struct SystemProfile: Sendable, Equatable {
    public var physicalMemoryGB: Int
    public var suggestedTextModel: String

    public static func current() -> SystemProfile {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = max(1, Int(bytes / (1024 * 1024 * 1024)))

        // RAM is the binding constraint for local Gemma 4, pick the tag that fits.
        let model: String
        if gb <= 16 {
            model = "gemma4:e2b"
        } else if gb <= 24 {
            model = "gemma4:e4b"
        } else {
            model = "gemma4:26b"
        }

        return SystemProfile(physicalMemoryGB: gb, suggestedTextModel: model)
    }
}

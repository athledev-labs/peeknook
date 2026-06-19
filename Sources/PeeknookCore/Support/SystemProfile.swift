// SPDX-License-Identifier: Apache-2.0

import Foundation

/// On-device signals for Settings → System & usage (no network).
public struct SystemProfile: Sendable, Equatable {
    public var physicalMemoryGB: Int
    public var suggestedTextModel: String

    public static func current() -> SystemProfile {
        let bytes = ProcessInfo.processInfo.physicalMemory
        let gb = max(1, Int(bytes / (1024 * 1024 * 1024)))
        return SystemProfile(physicalMemoryGB: gb, suggestedTextModel: recommendedModel(forPhysicalMemoryGB: gb))
    }

    /// The largest local Gemma 4 tag that leaves real headroom for macOS and the user's other apps.
    /// A resident vision model is the dominant memory cost, so the thresholds are deliberately
    /// conservative: total RAM must comfortably exceed the model's working set, not merely fit it.
    /// e4b (~10 GB resident) on an 18–24 GB Mac left almost no room and could thrash the whole
    /// system, so e4b now needs ≥32 GB and 26b (~18 GB resident) needs ≥48 GB; everything below
    /// gets e2b. Pure (no global reads) so the tiers are unit-testable.
    public static func recommendedModel(forPhysicalMemoryGB gb: Int) -> String {
        if gb < 32 {
            return "gemma4:e2b"
        } else if gb < 48 {
            return "gemma4:e4b"
        } else {
            return "gemma4:26b"
        }
    }
}

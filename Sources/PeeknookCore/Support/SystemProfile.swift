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

    /// The suggested default answer model for a Mac with this much RAM. A resident vision model is the
    /// dominant memory cost, so the per-model floors are deliberately conservative: total RAM must
    /// comfortably exceed the model's working set, not merely fit it.
    ///
    /// The RAM→model policy itself lives in the catalog, not here: each curated model carries a
    /// ``InferenceModelOption/recommendedRAMFloorGB`` and ``TextModelCatalog/recommendedTag(forPhysicalMemoryGB:)``
    /// picks the most capable model the Mac can afford. With today's floors that means e2b below 16 GB,
    /// Qwen2.5-VL 7B (reads detailed screens well, fits where Gemma e4b's ~10 GB resident could not)
    /// through the common 16–31 GB range, then e4b (≥32 GB) and 26b (≥48 GB). Re-tiering is a one-line
    /// catalog edit; this method just delegates so there is no parallel ladder to keep in sync.
    public static func recommendedModel(forPhysicalMemoryGB gb: Int) -> String {
        TextModelCatalog.recommendedTag(forPhysicalMemoryGB: gb)
    }
}

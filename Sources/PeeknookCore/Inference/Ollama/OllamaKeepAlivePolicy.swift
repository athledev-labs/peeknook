// SPDX-License-Identifier: Apache-2.0

import Foundation

/// How long Ollama should keep the answer model resident after a call (`keep_alive`).
///
/// A warm model skips the ~13 s cold start, but a resident multi-GB vision model is the single
/// largest memory cost Peeknook drives. On a RAM-constrained Mac, holding ~10 GB resident for a
/// full 10 minutes after one capture sustains memory pressure long after the user is done — the
/// kind of overcommit that swaps the whole system. So the window scales with the same RAM tiers
/// `SystemProfile` uses to pick the model: low-RAM Macs release the model sooner (trading a little
/// warmth for headroom); roomy Macs keep the original 10-minute window.
///
/// Pure (no global reads) so the mapping is unit-testable; `recommended*()` reads real RAM once.
public enum OllamaKeepAlivePolicy {
    /// The `keep_alive` window in seconds for this RAM tier — the single source the string form and
    /// the warm-gate window both derive from, so they can never disagree.
    public static func keepAliveSeconds(forPhysicalMemoryGB gb: Int) -> Int {
        if gb < 24 {
            return 120          // e2b tier / tight RAM: free the weights quickly (2m)
        } else if gb < 48 {
            return 300          // mid tier: a moderate warm window (5m)
        } else {
            return 600          // ample RAM: the original always-warm window (10m)
        }
    }

    /// The value sent as Ollama's `keep_alive` (e.g. `"120s"`). Ollama accepts a bare seconds suffix.
    public static func keepAlive(forPhysicalMemoryGB gb: Int) -> String {
        "\(keepAliveSeconds(forPhysicalMemoryGB: gb))s"
    }

    /// How long the in-session "model is probably still warm" gate should trust, just under the real
    /// `keep_alive` so the gate flips to cold *before* Ollama actually evicts (never claims warm when
    /// the weights are already gone). Mirrors the original 10m→9m (540 s) margin for the top tier.
    public static func warmWindowSeconds(forPhysicalMemoryGB gb: Int) -> TimeInterval {
        TimeInterval(max(30, keepAliveSeconds(forPhysicalMemoryGB: gb) - 60))
    }

    public static func recommended() -> String {
        keepAlive(forPhysicalMemoryGB: SystemProfile.current().physicalMemoryGB)
    }

    public static func recommendedWarmWindowSeconds() -> TimeInterval {
        warmWindowSeconds(forPhysicalMemoryGB: SystemProfile.current().physicalMemoryGB)
    }
}

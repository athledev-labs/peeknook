// SPDX-License-Identifier: Apache-2.0

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A point-in-time read of system RAM, used to warn before Peeknook asks Ollama to load a
/// multi-GB vision model that won't fit. `availableBytes` is the memory that could be handed to a
/// new allocation without swapping (free + reclaimable), the honest counterpart to "you have ~N GB
/// free" — not total RAM.
public struct SystemMemorySnapshot: Sendable, Equatable {
    public var physicalBytes: Int64
    public var availableBytes: Int64

    public init(physicalBytes: Int64, availableBytes: Int64) {
        self.physicalBytes = physicalBytes
        self.availableBytes = availableBytes
    }

    /// Live read. `availableBytes` falls back to physical RAM if the Mach probe fails, so a probe
    /// error never manufactures a false "won't fit" warning.
    public static func current() -> SystemMemorySnapshot {
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        return SystemMemorySnapshot(
            physicalBytes: physical,
            availableBytes: reclaimableBytes() ?? physical
        )
    }

    /// free + inactive + speculative + purgeable pages — memory the kernel can reclaim for a new
    /// allocation without paging active memory to disk. nil if the Mach call fails.
    private static func reclaimableBytes() -> Int64? {
        #if canImport(Darwin)
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let host = mach_host_self()
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = Int64(sysconf(_SC_PAGESIZE))
        let pages = Int64(stats.free_count)
            + Int64(stats.inactive_count)
            + Int64(stats.speculative_count)
            + Int64(stats.purgeable_count)
        return pages * pageSize
        #else
        return nil
        #endif
    }
}

/// Whether a model's resident footprint comfortably fits the current memory state.
public enum ModelMemoryFit: Sendable, Equatable {
    /// Loads with headroom to spare for macOS and the user's other apps.
    case fits
    /// Will load, but leaves little slack — capture is fine, just close to the edge.
    case tight
    /// Loading is likely to overcommit RAM and swap-thrash the whole system. Warn before loading.
    case insufficient
}

/// Pure pre-flight check: does a model of roughly `modelBytes` (its download size, the best offline
/// proxy for resident weight) fit the live memory snapshot? Returns nil when the size is unknown
/// (custom tag with no hint) — a false warning is worse than none, mirroring the disk pre-check.
public enum ModelMemoryPolicy {
    /// Headroom we want left for macOS + foreground apps for a load to count as comfortable.
    static let reserveBytes: Int64 = 3_000_000_000

    public static func fit(modelBytes: Int64?, snapshot: SystemMemorySnapshot) -> ModelMemoryFit? {
        guard let modelBytes, modelBytes > 0 else { return nil }
        // Resident footprint runs above the download size (KV cache, vision encoder, runtime).
        let required = modelBytes + modelBytes / 5   // ~+20% working set
        let available = snapshot.availableBytes
        if available >= required + reserveBytes { return .fits }
        if available >= required { return .tight }
        return .insufficient
    }

    /// GB figures for the user-facing warning. `needGB` is the catalog-sized model footprint (what the
    /// user already saw on the download row), `totalGB` is the Mac's total RAM. The warning reports
    /// total (a stable, understandable number) rather than the instantaneously-free figure, which
    /// fluctuates and reads as alarming ("only 3 GB?!") when the Mac actually has plenty installed and
    /// is merely busy. The copy explains that most of it is in use right now.
    public static func warningGigabytes(
        modelBytes: Int64,
        snapshot: SystemMemorySnapshot
    ) -> (needGB: Int, totalGB: Int) {
        (
            needGB: max(1, Int((Double(modelBytes) / 1_000_000_000).rounded())),
            totalGB: max(1, Int((Double(snapshot.physicalBytes) / 1_000_000_000).rounded()))
        )
    }
}

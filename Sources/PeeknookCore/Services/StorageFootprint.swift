// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Human-readable storage sizes for Settings footprint rows (disk, not activity estimates).
public enum ByteFormat: Sendable {
    public static func storage(_ bytes: Int) -> String {
        storage(Int64(bytes))
    }

    public static func storage(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    /// Parses a catalog download hint like "~7 GB" / "10 GB" into a byte count, using decimal GB to
    /// match `ByteCountFormatter.file` (so a "needs N free" message reads consistently with `storage`).
    /// Returns nil for nil or unparseable hints (e.g. a custom tag with no size) — the disk pre-check
    /// then skips, since a false block is worse than no block.
    public static func bytes(fromGigabytesHint hint: String?) -> Int64? {
        guard let hint else { return nil }
        let scanner = Scanner(string: hint)
        _ = scanner.scanUpToCharacters(from: .decimalDigits)   // skip a leading "~" etc.
        guard let value = scanner.scanDouble(), value > 0 else { return nil }
        return Int64(value * 1_000_000_000)
    }
}

/// On-disk conversation archive usage aligned with ``ConversationArchiveStore`` retention caps.
public struct ConversationArchiveFootprint: Sendable, Equatable {
    public var threadCount: Int
    public var usedBytes: Int
    public var maxBytes: Int
    public var maxThreads: Int

    public var byteFraction: Double {
        guard maxBytes > 0 else { return 0 }
        return min(1, Double(usedBytes) / Double(maxBytes))
    }

    public init(
        threadCount: Int,
        usedBytes: Int,
        maxBytes: Int = ConversationArchiveStore.defaultMaxBytes,
        maxThreads: Int = ConversationArchiveStore.defaultMaxThreads
    ) {
        self.threadCount = threadCount
        self.usedBytes = usedBytes
        self.maxBytes = maxBytes
        self.maxThreads = maxThreads
    }
}

public enum ArchiveFootprintState: Sendable, Equatable {
    case disabled
    case empty
    case inUse(ConversationArchiveFootprint)
    case unavailable(reason: String)
}

public struct OllamaDiskFootprint: Sendable, Equatable {
    public var modelCount: Int
    public var totalBytes: Int64

    public init(modelCount: Int, totalBytes: Int64) {
        self.modelCount = modelCount
        self.totalBytes = totalBytes
    }
}

public struct OllamaLoadedModelFootprint: Sendable, Equatable {
    public var name: String
    public var sizeBytes: Int64

    public init(name: String, sizeBytes: Int64) {
        self.name = name
        self.sizeBytes = sizeBytes
    }
}

public enum OllamaFootprintState: Sendable, Equatable {
    case local(OllamaDiskFootprint)
    case unavailable(reason: String)
}

public enum OllamaMemoryFootprintState: Sendable, Equatable {
    case noneLoaded
    case loaded([OllamaLoadedModelFootprint])
    case unavailable(reason: String)
}

/// Point-in-time storage snapshot for Settings → Data. Activity counters live in ``UsageStats``.
public struct StorageFootprintSnapshot: Sendable, Equatable {
    public var archive: ArchiveFootprintState
    public var ollamaDisk: OllamaFootprintState
    public var ollamaMemory: OllamaMemoryFootprintState
    public var systemMemoryGB: Int
    public var suggestedTextModel: String

    public init(
        archive: ArchiveFootprintState,
        ollamaDisk: OllamaFootprintState,
        ollamaMemory: OllamaMemoryFootprintState,
        systemMemoryGB: Int,
        suggestedTextModel: String
    ) {
        self.archive = archive
        self.ollamaDisk = ollamaDisk
        self.ollamaMemory = ollamaMemory
        self.systemMemoryGB = systemMemoryGB
        self.suggestedTextModel = suggestedTextModel
    }
}

/// Aggregates on-device footprint sources for Settings (no telemetry, no remote disk walks).
public protocol StorageFootprinting: Sendable {
    func snapshot(
        persistConversation: Bool,
        ollamaBaseURL: String,
        acceptInsecureRemoteOllama: Bool
    ) async -> StorageFootprintSnapshot
}

public struct StorageFootprintService: StorageFootprinting, Sendable {
    public var archive: ConversationArchiveStore?
    public var ollama: OllamaSetupClient
    public var systemProfile: @Sendable () -> SystemProfile

    public init(
        archive: ConversationArchiveStore? = nil,
        ollama: OllamaSetupClient = OllamaSetupClient(),
        systemProfile: @escaping @Sendable () -> SystemProfile = { SystemProfile.current() }
    ) {
        self.archive = archive
        self.ollama = ollama
        self.systemProfile = systemProfile
    }

    public func snapshot(
        persistConversation: Bool,
        ollamaBaseURL: String,
        acceptInsecureRemoteOllama: Bool
    ) async -> StorageFootprintSnapshot {
        let profile = systemProfile()
        let archiveState = await archiveState(persistConversation: persistConversation)
        let diskState: OllamaFootprintState
        let memoryState: OllamaMemoryFootprintState
        if EndpointURLPolicy.usesRemoteHost(ollamaBaseURL) {
            let reason = "Disk and memory usage are only shown for local Ollama."
            diskState = .unavailable(reason: reason)
            memoryState = .unavailable(reason: reason)
        } else {
            diskState = await localOllamaDisk(
                baseURL: ollamaBaseURL,
                acceptInsecureRemote: acceptInsecureRemoteOllama
            )
            memoryState = await localOllamaMemory(
                baseURL: ollamaBaseURL,
                acceptInsecureRemote: acceptInsecureRemoteOllama
            )
        }
        return StorageFootprintSnapshot(
            archive: archiveState,
            ollamaDisk: diskState,
            ollamaMemory: memoryState,
            systemMemoryGB: profile.physicalMemoryGB,
            suggestedTextModel: profile.suggestedTextModel
        )
    }

    private func archiveState(persistConversation: Bool) async -> ArchiveFootprintState {
        guard persistConversation else { return .disabled }
        guard let archive else {
            return .unavailable(reason: "Conversation archive is unavailable on this Mac.")
        }
        let footprint = await archive.footprint()
        if footprint.threadCount == 0, footprint.usedBytes == 0 {
            return .empty
        }
        return .inUse(footprint)
    }

    private func localOllamaDisk(
        baseURL: String,
        acceptInsecureRemote: Bool
    ) async -> OllamaFootprintState {
        do {
            let models = try await ollama.installedModelFootprints(
                baseURL: baseURL,
                acceptInsecureRemote: acceptInsecureRemote
            )
            let total = models.reduce(Int64(0)) { $0 + $1.sizeBytes }
            return .local(OllamaDiskFootprint(modelCount: models.count, totalBytes: total))
        } catch let error as InferenceError {
            return .unavailable(reason: error.localizedDescription)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    private func localOllamaMemory(
        baseURL: String,
        acceptInsecureRemote: Bool
    ) async -> OllamaMemoryFootprintState {
        do {
            let running = try await ollama.runningModelFootprints(
                baseURL: baseURL,
                acceptInsecureRemote: acceptInsecureRemote
            )
            if running.isEmpty { return .noneLoaded }
            return .loaded(running)
        } catch let error as InferenceError {
            return .unavailable(reason: error.localizedDescription)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }
}

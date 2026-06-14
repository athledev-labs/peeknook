// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Free-disk-space probe for the model-download pre-check. Injectable so ``SetupCoordinator``'s disk
/// gate is testable without touching the real filesystem.
public protocol ModelStorageProbe: Sendable {
    /// Bytes available for an important download on the volume holding the Ollama model store, or nil
    /// when it can't be determined (the gate then skips — a false block is worse than no block).
    func availableBytesForModelStore() -> Int64?
}

/// Resolves the local Ollama model store (`OLLAMA_MODELS` env → else `~/.ollama/models`, falling back
/// to the nearest existing parent so a first-run probe still reads the right volume) and reads its
/// available capacity for important usage.
public struct FileManagerModelStorageProbe: ModelStorageProbe {
    public init() {}

    public func availableBytesForModelStore() -> Int64? {
        let url = Self.resolveModelsDirectory()
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let available = values.volumeAvailableCapacityForImportantUsage else {
            return nil
        }
        return Int64(available)
    }

    static func resolveModelsDirectory() -> URL {
        let fm = FileManager.default
        let base: URL
        if let env = ProcessInfo.processInfo.environment["OLLAMA_MODELS"], !env.isEmpty {
            base = URL(fileURLWithPath: env)
        } else {
            base = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ollama/models")
        }
        var url = base
        while !fm.fileExists(atPath: url.path) {
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }   // reached the volume root
            url = parent
        }
        return url
    }
}

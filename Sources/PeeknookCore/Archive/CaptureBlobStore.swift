// SPDX-License-Identifier: Apache-2.0

import Foundation

/// External screenshot storage for chat threads. Image turns reference blob ids on disk instead of
/// embedding JPEG base64 in every ``ChatTurn`` and archive JSON file.
public protocol CaptureBlobStoring: Sendable {
    func store(jpegBase64: String) throws -> UUID
    func loadBase64(id: UUID) throws -> String?
    func delete(ids: Set<UUID>) throws
    func deleteAll() throws
}

public enum CaptureBlobError: Error, Sendable, Equatable {
    case invalidBase64
    case writeFailed
}

/// Thread-safe JPEG blob files under `<conversations>/blobs/<uuid>.jpg`.
public final class CaptureBlobStore: CaptureBlobStoring, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    public static func makeDefault(conversationsDirectory: URL) -> CaptureBlobStore {
        CaptureBlobStore(directory: conversationsDirectory.appendingPathComponent("blobs", isDirectory: true))
    }

    public func store(jpegBase64: String) throws -> UUID {
        guard let data = Data(base64Encoded: jpegBase64), !data.isEmpty else {
            throw CaptureBlobError.invalidBase64
        }
        let id = UUID()
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try data.write(to: blobURL(id), options: [.atomic, .completeFileProtection])
        } catch {
            throw CaptureBlobError.writeFailed
        }
        return id
    }

    public func loadBase64(id: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: blobURL(id)), !data.isEmpty else { return nil }
        return data.base64EncodedString()
    }

    public func delete(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for id in ids {
            try? FileManager.default.removeItem(at: blobURL(id))
        }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: directory)
    }

    func blobURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}

public enum CaptureBlobReferences {
    public static func blobIDs(in turns: [ChatTurn]) -> Set<UUID> {
        var ids = Set<UUID>()
        for turn in turns {
            guard case .image(let capture) = turn.kind, let id = capture.screenshotBlobID else { continue }
            ids.insert(id)
        }
        return ids
    }

    /// Move inline screenshots into blob files and strip base64 from the turns. Returns whether any
    /// turn changed. Invalid JPEG base64 is left inline so legacy/stub captures still persist.
    @discardableResult
    public static func externalizeInlineScreenshots(in turns: inout [ChatTurn], using store: CaptureBlobStoring) -> Bool {
        var changed = false
        for index in turns.indices {
            guard case .image(var capture) = turns[index].kind else { continue }
            guard capture.screenshotBlobID == nil,
                  let base64 = capture.screenshotBase64,
                  !base64.isEmpty,
                  let id = try? store.store(jpegBase64: base64) else { continue }
            capture.screenshotBase64 = nil
            capture.screenshotBlobID = id
            turns[index].kind = .image(capture)
            changed = true
        }
        return changed
    }
}

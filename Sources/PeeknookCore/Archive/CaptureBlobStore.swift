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
    case readFailed
}

/// Thread-safe screenshot blob files under `<conversations>/blobs/<uuid>.jpg`.
/// When ``ConversationArchiveProtection`` is wired in, JPEG bytes are AES-GCM sealed with the same
/// device-local key as thread JSON. Legacy installs may still have plaintext JPEG blobs on disk;
/// those are read transparently until rewritten.
public final class CaptureBlobStore: CaptureBlobStoring, @unchecked Sendable {
    private let directory: URL
    private let protection: (any ConversationArchiveProtection)?
    private let lock = NSLock()

    public init(directory: URL, protection: (any ConversationArchiveProtection)? = nil) {
        self.directory = directory
        self.protection = protection
    }

    public static func makeDefault(
        conversationsDirectory: URL,
        protection: (any ConversationArchiveProtection)? = nil
    ) -> CaptureBlobStore {
        CaptureBlobStore(
            directory: conversationsDirectory.appendingPathComponent("blobs", isDirectory: true),
            protection: protection
        )
    }

    public func store(jpegBase64: String) throws -> UUID {
        guard let data = Data(base64Encoded: jpegBase64), !data.isEmpty else {
            throw CaptureBlobError.invalidBase64
        }
        let id = UUID()
        let payload: Data
        if let protection {
            do {
                payload = try protection.seal(data)
            } catch {
                throw CaptureBlobError.writeFailed
            }
        } else {
            payload = data
        }
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try payload.write(to: blobURL(id), options: [.atomic, .completeFileProtection])
        } catch {
            throw CaptureBlobError.writeFailed
        }
        return id
    }

    public func loadBase64(id: UUID) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try? Data(contentsOf: blobURL(id)), !raw.isEmpty else { return nil }
        let jpeg: Data
        if ArchiveEnvelope.isEncrypted(raw), let protection {
            do {
                jpeg = try protection.open(raw)
            } catch {
                throw CaptureBlobError.readFailed
            }
        } else if ArchiveEnvelope.isEncrypted(raw) {
            throw CaptureBlobError.readFailed
        } else {
            jpeg = raw
        }
        return jpeg.base64EncodedString()
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

    /// Total bytes of screenshot blob files on disk (encrypted or legacy plaintext).
    public func bytesOnDisk() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(0) { running, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return running + size
        }
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

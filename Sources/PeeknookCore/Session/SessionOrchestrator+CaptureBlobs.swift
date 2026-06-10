// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    /// External screenshot storage shared with the conversation archive. Blobs are written only when
    /// ``PeeknookSettings/persistConversation`` is enabled.
    public var captureBlobStore: CaptureBlobStore? {
        get { _captureBlobStore }
        set { _captureBlobStore = newValue }
    }

    /// Resolved JPEG base64 for a capture turn (inline, cache, or blob file).
    public func screenshotBase64(for capture: CaptureResult) -> String? {
        if let inline = capture.screenshotBase64, !inline.isEmpty { return inline }
        return archiveThumbnailBase64(blobID: capture.screenshotBlobID)
    }

    /// Lazy blob load for History row thumbnails (cache-backed).
    public func archiveThumbnailBase64(blobID: UUID?) -> String? {
        guard let id = blobID else { return nil }
        if let cached = screenshotCache[id] { return cached }
        guard let store = captureBlobStore,
              let loaded = try? store.loadBase64(id: id) else { return nil }
        screenshotCache[id] = loaded
        return loaded
    }

    func storedCapture(_ capture: CaptureResult) -> CaptureResult {
        // The same per-profile write gate as the thread save, keyed by THIS capture's ground —
        // a blob must never be written for a turn whose thread save is gated off (orphan).
        guard moduleEnabled(.saveConversation, for: gatingProfile(forTurnGround: capture.ground)),
              let base64 = capture.screenshotBase64,
              !base64.isEmpty,
              let store = captureBlobStore else { return capture }
        guard let id = try? store.store(jpegBase64: base64) else { return capture }
        sessionBlobIDs.insert(id)
        return CaptureResult(
            text: capture.text,
            sourceLabel: capture.sourceLabel,
            appName: capture.appName,
            windowTitle: capture.windowTitle,
            screenshotBlobID: id,
            ground: capture.ground
        )
    }

    func preloadImageBase64(for turns: [ChatTurn], replayIDs: Set<Int>) -> [Int: String] {
        var loaded: [Int: String] = [:]
        for turn in turns where replayIDs.contains(turn.id) {
            guard case .image(let capture) = turn.kind,
                  let base64 = screenshotBase64(for: capture) else { continue }
            loaded[turn.id] = base64
        }
        return loaded
    }

    func purgeSessionBlobs() {
        guard let store = captureBlobStore, !sessionBlobIDs.isEmpty else {
            sessionBlobIDs.removeAll()
            screenshotCache.removeAll()
            return
        }
        try? store.delete(ids: sessionBlobIDs)
        sessionBlobIDs.removeAll()
        screenshotCache.removeAll()
    }

    func adoptBlobOwnership(from thread: ConversationThread) {
        sessionBlobIDs.removeAll()
        screenshotCache.removeAll()
        for id in CaptureBlobReferences.blobIDs(in: thread.turns) {
            sessionBlobIDs.insert(id)
        }
    }
}

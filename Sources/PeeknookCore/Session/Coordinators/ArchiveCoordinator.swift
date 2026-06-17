// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Conversation-archive domain: the opt-in local thread archive (list/resume/rename/delete/purge),
/// the active thread's archive identity, and externalized screenshot blobs. Owned by
/// ``SessionOrchestrator``; UI binds to the facade, which delegates here. The blob write and the
/// thread save share one per-profile verdict (see `archiveWritesEnabled`) so neither can orphan
/// the other.
@MainActor
final class ArchiveCoordinator {
    private weak var session: SessionOrchestrator?

    /// Identity of the chat currently on screen within the archive. Assigned on first save, carried
    /// across follow-ups, cleared when a fresh chat begins. Nil means "not yet archived".
    private(set) var activeThreadID: UUID?
    private var activeThreadCreatedAt: Date?
    private var activeThreadCustomTitle: String?

    /// External screenshot storage shared with the conversation archive. Blobs are written only when
    /// ``PeeknookSettings/persistConversation`` is enabled.
    var captureBlobStore: CaptureBlobStore?
    /// Blob ids written during the current in-memory session (purged on New chat when not archived).
    private var sessionBlobIDs = Set<UUID>()
    /// Blob ids adopted when reopening an archived thread. These live on disk and are owned by the
    /// archive store (deleted only when the thread file is removed), so a session-side purge must
    /// never touch them — otherwise a fresh Retake on an open archived chat would erase its saved
    /// screenshots while the thread stays listed and reopenable.
    private var adoptedBlobIDs = Set<UUID>()
    private var screenshotCache: [UUID: String] = [:]

    private var archiveIOTask: Task<Void, Never>?

    init(session: SessionOrchestrator) {
        self.session = session
    }

    // MARK: - Conversation archive (opt-in, local files)

    /// Restore the most recent saved chat at launch when the user has persistence enabled (migrating
    /// the legacy single-file store first). Leaves the phase at `.idle` so it surfaces as a resumable
    /// thread, not an auto-opened result.
    func loadPersistedConversationIfEnabled() {
        guard let session, session.settings.persistConversation,
              let archive = session.conversationArchive else { return }
        let generation = session.lifecycle.snapshotSession()
        Task {
            _ = await archive.migrateLegacyIfNeeded()
            _ = await archive.reencryptPlaintextThreadsIfNeeded()
            _ = await archive.reencryptPlaintextIndexIfNeeded()
            guard let restored = await archive.mostRecent(), !restored.turns.isEmpty else { return }
            guard session.lifecycle.isCurrentSession(generation), case .idle = session.phase,
                  session.conversation.isEmpty else { return }
            adopt(restored)
        }
    }

    /// Summaries of every archived chat (newest first) for the History switcher. Empty when
    /// persistence is off or nothing is saved.
    func availableThreads() async -> [ConversationSummary] {
        guard let session, session.settings.persistConversation else { return [] }
        guard let archive = session.conversationArchive else { return [] }
        return await archive.summaries()
    }

    /// Open an archived chat by id: load it into memory and surface its last answer as a result.
    func openThread(id: UUID) async {
        guard let session, session.settings.persistConversation,
              let archive = session.conversationArchive else { return }
        let generation = session.lifecycle.snapshotSession()
        guard let thread = await archive.load(id: id), !thread.turns.isEmpty else {
            // The row is listed in the index but its thread file is missing, corrupt, or refused
            // (tamper / downgrade). Don't no-op silently: prune the dead index entry so the row stops
            // dangling, and surface a one-shot notice instead of an unexplained dead tap.
            guard session.lifecycle.isCurrentSession(generation) else { return }
            enqueueArchiveIO { await $0.delete(id: id) }
            session.emitNotice(.threadUnavailable)
            return
        }
        guard session.lifecycle.isCurrentSession(generation) else { return }
        session.abortSessionWork()
        session.stopLiveSession()   // switching threads ends the armed session for the old thread
        session.suggestedFollowUps = []
        session.streamedAnswer = ""
        adopt(thread)
        _ = session.applyPhaseEvent(.openThreadRestored(answer: session.lastAssistantText ?? ""))
    }

    /// Rename one archived chat. Empty title clears a custom name and reverts to the derived label.
    func renameThread(id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle: String? = trimmed.isEmpty ? nil : trimmed
        enqueueArchiveIO { archive in
            _ = await archive.rename(id: id, customTitle: customTitle)
        }
        if id == activeThreadID {
            activeThreadCustomTitle = customTitle
        }
    }

    /// Delete one archived chat. If it's the one on screen, also clear it from memory and return idle.
    func deleteThread(id: UUID) {
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        if id == activeThreadID, let session {
            // Deleting the chat that's currently on screen: abort any in-flight inference first, or
            // a late stream could re-file an answer for the thread we just removed.
            session.abortSessionWork()
            session.stopLiveSession()   // the deleted thread's armed session ends with it
            session.resetConversation()
            _ = session.applyPhaseEvent(.deleteActiveThreadToIdle)
        }
    }

    private func adopt(_ thread: ConversationThread) {
        guard let session else { return }
        adoptBlobOwnership(from: thread)
        session.conversation = thread.turns
        session.contextWindow = thread.contextWindow
        session.lastPromptTokens = thread.lastPromptTokens
        session.turnCounter = max(thread.turnCounter, thread.turns.map(\.id).max() ?? 0)
        activeThreadID = thread.id
        activeThreadCreatedAt = thread.createdAt
        activeThreadCustomTitle = thread.customTitle
    }

    /// Write the current chat to the archive (off the main actor) when persistence is on; no-op
    /// otherwise. The first save mints the thread's stable id and creation date.
    /// Write-gated per profile (the same verdict as the blob write — see `archiveWritesEnabled`);
    /// restore/list/resume and purge-on-disable stay on the global toggle.
    func persistConversationNow() {
        guard let session, session.archiveWritesEnabled, session.conversationArchive != nil,
              !session.conversation.isEmpty else { return }
        if activeThreadID == nil {
            activeThreadID = UUID()
            activeThreadCreatedAt = Date()
        }
        let thread = ConversationThread(
            id: activeThreadID ?? UUID(),
            createdAt: activeThreadCreatedAt ?? Date(),
            updatedAt: Date(),
            turns: session.conversation,
            contextWindow: session.contextWindow,
            turnCounter: session.turnCounter,
            lastPromptTokens: session.lastPromptTokens,
            customTitle: activeThreadCustomTitle
        )
        enqueueArchiveIO { archive in
            let result = await archive.save(thread)
            await MainActor.run {
                switch result {
                case .success:
                    session.archivePersistenceIssue = nil
                case .failure(let error):
                    session.archivePersistenceIssue = error
                }
            }
        }
    }

    /// Delete just the chat on screen from the archive, called when the user discards a thread.
    func discardActiveThread() {
        guard let id = activeThreadID else {
            activeThreadCreatedAt = nil
            activeThreadCustomTitle = nil
            return
        }
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        clearActiveThreadIdentity()
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    func purgeAllConversations() {
        guard let session else { return }
        session.abortSessionWork()
        session.stopLiveSession()   // wiping everything returns to idle — disarm (resetConversation
                                    // must NOT, since a Retake's .fresh commit funnels through it)
        session.streamedAnswer = ""
        session.sessionBrief = ""
        session.lifecycle.clearPendingCapture()
        enqueueArchiveIO { archive in
            await archive.deleteAll()
        }
        session.resetConversation()
        _ = session.applyPhaseEvent(.deleteActiveThreadToIdle)
        session.archivePersistenceIssue = nil
    }

    /// Forgets the on-screen chat's archive identity (without deleting the archived thread) so the
    /// next answered chat is filed as a new entry. Part of the facade's `resetConversation`.
    func clearActiveThreadIdentity() {
        activeThreadID = nil
        activeThreadCreatedAt = nil
        activeThreadCustomTitle = nil
    }

    /// Serializes archive read/write so delete/purge cannot race a late save.
    private func enqueueArchiveIO(_ operation: @escaping (ConversationArchiveStore) async -> Void) {
        guard let session, let archive = session.conversationArchive else { return }
        let prior = archiveIOTask
        archiveIOTask = Task {
            _ = await prior?.value
            guard !Task.isCancelled else { return }
            await operation(archive)
            await MainActor.run { session.bumpArchiveRevision() }
        }
    }

    // MARK: - Screenshot blobs

    /// Resolved JPEG base64 for a capture turn (inline, cache, or blob file).
    func screenshotBase64(for capture: CaptureResult) -> String? {
        if let inline = capture.screenshotBase64, !inline.isEmpty { return inline }
        return archiveThumbnailBase64(blobID: capture.screenshotBlobID)
    }

    /// Lazy blob load for History row thumbnails (cache-backed).
    func archiveThumbnailBase64(blobID: UUID?) -> String? {
        guard let id = blobID else { return nil }
        if let cached = screenshotCache[id] { return cached }
        guard let store = captureBlobStore,
              let loaded = try? store.loadBase64(id: id) else { return nil }
        screenshotCache[id] = loaded
        return loaded
    }

    /// Off-main variant for History row thumbnails. The cache lookup/update stays on the main actor,
    /// but the blob disk read + decode run on a background task so scrolling History doesn't stutter
    /// the main thread per row. `CaptureBlobStore` is `Sendable` (lock-guarded), so the read is safe
    /// off the main actor.
    func loadArchiveThumbnailBase64(blobID: UUID?) async -> String? {
        guard let id = blobID else { return nil }
        if let cached = screenshotCache[id] { return cached }
        guard let store = captureBlobStore else { return nil }
        let loaded = await Task.detached(priority: .utility) {
            try? store.loadBase64(id: id)
        }.value
        if let loaded { screenshotCache[id] = loaded }
        return loaded
    }

    func storedCapture(_ capture: CaptureResult) -> CaptureResult {
        // The same per-profile write gate as the thread save, keyed by THIS capture's ground —
        // a blob must never be written for a turn whose thread save is gated off (orphan).
        guard let session,
              session.moduleEnabled(.saveConversation, for: session.gatingProfile(forTurnGround: capture.ground)),
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
        // Only delete session-minted blobs. Blobs adopted from a reopened archived thread stay on
        // disk for the archive store to garbage-collect when the thread itself is removed.
        let purgeable = sessionBlobIDs.subtracting(adoptedBlobIDs)
        if let store = captureBlobStore, !purgeable.isEmpty {
            try? store.delete(ids: purgeable)
        }
        sessionBlobIDs.removeAll()
        adoptedBlobIDs.removeAll()
        screenshotCache.removeAll()
    }

    private func adoptBlobOwnership(from thread: ConversationThread) {
        sessionBlobIDs.removeAll()
        adoptedBlobIDs.removeAll()
        screenshotCache.removeAll()
        let ids = CaptureBlobReferences.blobIDs(in: thread.turns)
        adoptedBlobIDs = ids
        // Track them as session ids too so the not-archived discard paths still account for them; the
        // archive-owned ones are filtered back out in `purgeSessionBlobs` so a Retake can't erase them.
        sessionBlobIDs = ids
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

@MainActor
extension SessionOrchestrator {
    // MARK: - Conversation archive (opt-in, local files)

    /// Restore the most recent saved chat at launch when the user has persistence enabled (migrating
    /// the legacy single-file store first). Leaves the phase at `.idle` so it surfaces as a resumable
    /// thread, not an auto-opened result.
    public func loadPersistedConversationIfEnabled() {
        guard settings.persistConversation, let archive = conversationArchive else { return }
        let generation = sessionGeneration
        Task {
            _ = await archive.migrateLegacyIfNeeded()
            _ = await archive.reencryptPlaintextThreadsIfNeeded()
            _ = await archive.reencryptPlaintextIndexIfNeeded()
            guard let restored = await archive.mostRecent(), !restored.turns.isEmpty else { return }
            // A capture or thread switch started while we were loading off-disk — never adopt the
            // stale thread over the user's in-flight work. Stay defensive: only restore into a
            // genuinely idle, empty session.
            guard generation == sessionGeneration, case .idle = phase, conversation.isEmpty else { return }
            adopt(restored)
        }
    }

    /// Summaries of every archived chat (newest first) for the History switcher. Empty when
    /// persistence is off or nothing is saved.
    public func availableThreads() async -> [ConversationSummary] {
        guard settings.persistConversation else { return [] }
        guard let archive = conversationArchive else { return [] }
        return await archive.summaries()
    }

    /// Open an archived chat by id: load it into memory and surface its last answer as a result.
    public func openThread(id: UUID) async {
        // Never surface archived content when the user has persistence off — the History switcher is
        // hidden then, but guard here too so a stale id can't resurrect an opted-out chat.
        // Never surface archived content when the user has persistence off — the History switcher is
        // hidden then, but guard here too so a stale id can't resurrect an opted-out chat.
        guard settings.persistConversation, let archive = conversationArchive else { return }
        let generation = sessionGeneration
        guard let thread = await archive.load(id: id), !thread.turns.isEmpty else { return }
        // A capture or another thread switch started while this one loaded off-disk — the newer
        // intent wins, so don't stomp it with the thread we were asked for earlier.
        guard generation == sessionGeneration else { return }
        abortSessionWork()
        suggestedFollowUps = []
        streamedAnswer = ""
        adopt(thread)
        phase = .result(lastAssistantText ?? "")
    }

    /// Delete one archived chat. If it's the one on screen, also clear it from memory and return idle.
    public func deleteThread(id: UUID) {
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        if id == activeThreadID {
            // Deleting the chat that's currently on screen: abort any in-flight inference first, or
            // a late stream could re-file an answer for the thread we just removed.
            abortSessionWork()
            resetConversation()
            phase = .idle
        }
    }

    private func adopt(_ thread: ConversationThread) {
        conversation = thread.turns
        contextWindow = thread.contextWindow
        lastPromptTokens = thread.lastPromptTokens
        turnCounter = max(thread.turnCounter, thread.turns.map(\.id).max() ?? 0)
        activeThreadID = thread.id
        activeThreadCreatedAt = thread.createdAt
    }

    /// Write the current chat to the archive (off the main actor) when persistence is on; no-op
    /// otherwise. The first save mints the thread's stable id and creation date.
    public func persistConversationNow() {
        guard settings.persistConversation, conversationArchive != nil, !conversation.isEmpty else { return }
        if activeThreadID == nil {
            activeThreadID = UUID()
            activeThreadCreatedAt = Date()
        }
        let thread = ConversationThread(
            id: activeThreadID ?? UUID(),
            createdAt: activeThreadCreatedAt ?? Date(),
            updatedAt: Date(),
            turns: conversation,
            contextWindow: contextWindow,
            turnCounter: turnCounter,
            lastPromptTokens: lastPromptTokens
        )
        enqueueArchiveIO { [self] archive in
            let result = await archive.save(thread)
            await MainActor.run {
                switch result {
                case .success:
                    archivePersistenceIssue = nil
                case .failure(let error):
                    archivePersistenceIssue = error
                }
            }
        }
    }

    public func dismissArchivePersistenceIssue() {
        archivePersistenceIssue = nil
    }

    /// Called when archive bootstrap fails (Keychain unavailable) so the user sees a banner before the first save.
    public func reportArchiveBootstrapFailure(_ error: ConversationArchiveError) {
        archivePersistenceIssue = error
    }

    /// Delete just the chat on screen from the archive, called when the user discards a thread.
    public func discardActiveThread() {
        guard let id = activeThreadID else {
            activeThreadCreatedAt = nil
            return
        }
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        activeThreadID = nil
        activeThreadCreatedAt = nil
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    public func purgeAllConversations() {
        enqueueArchiveIO { archive in
            await archive.deleteAll()
        }
        activeThreadID = nil
        activeThreadCreatedAt = nil
    }

    /// Serializes archive read/write so delete/purge cannot race a late save.
    private func enqueueArchiveIO(_ operation: @escaping (ConversationArchiveStore) async -> Void) {
        guard let archive = conversationArchive else { return }
        let prior = archiveIOTask
        archiveIOTask = Task {
            _ = await prior?.value
            guard !Task.isCancelled else { return }
            await operation(archive)
        }
    }
}

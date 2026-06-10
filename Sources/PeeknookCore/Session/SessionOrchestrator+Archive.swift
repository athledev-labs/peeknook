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
        let generation = lifecycle.snapshotSession()
        Task {
            _ = await archive.migrateLegacyIfNeeded()
            _ = await archive.reencryptPlaintextThreadsIfNeeded()
            _ = await archive.reencryptPlaintextIndexIfNeeded()
            guard let restored = await archive.mostRecent(), !restored.turns.isEmpty else { return }
            guard lifecycle.isCurrentSession(generation), case .idle = phase, conversation.isEmpty else { return }
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
        guard settings.persistConversation, let archive = conversationArchive else { return }
        let generation = lifecycle.snapshotSession()
        guard let thread = await archive.load(id: id), !thread.turns.isEmpty else { return }
        guard lifecycle.isCurrentSession(generation) else { return }
        abortSessionWork()
        suggestedFollowUps = []
        streamedAnswer = ""
        adopt(thread)
        _ = applyPhaseEvent(.openThreadRestored(answer: lastAssistantText ?? ""))
    }

    /// Rename one archived chat. Empty title clears a custom name and reverts to the derived label.
    public func renameThread(id: UUID, title: String) {
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
    public func deleteThread(id: UUID) {
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        if id == activeThreadID {
            // Deleting the chat that's currently on screen: abort any in-flight inference first, or
            // a late stream could re-file an answer for the thread we just removed.
            abortSessionWork()
            resetConversation()
            _ = applyPhaseEvent(.deleteActiveThreadToIdle)
        }
    }

    private func adopt(_ thread: ConversationThread) {
        adoptBlobOwnership(from: thread)
        conversation = thread.turns
        contextWindow = thread.contextWindow
        lastPromptTokens = thread.lastPromptTokens
        turnCounter = max(thread.turnCounter, thread.turns.map(\.id).max() ?? 0)
        activeThreadID = thread.id
        activeThreadCreatedAt = thread.createdAt
        activeThreadCustomTitle = thread.customTitle
    }

    /// Write the current chat to the archive (off the main actor) when persistence is on; no-op
    /// otherwise. The first save mints the thread's stable id and creation date.
    /// Write-gated per profile (the same verdict as the blob write — see `archiveWritesEnabled`);
    /// restore/list/resume and purge-on-disable stay on the global toggle.
    public func persistConversationNow() {
        guard archiveWritesEnabled, conversationArchive != nil, !conversation.isEmpty else { return }
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
            lastPromptTokens: lastPromptTokens,
            customTitle: activeThreadCustomTitle
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
            activeThreadCustomTitle = nil
            return
        }
        enqueueArchiveIO { archive in
            await archive.delete(id: id)
        }
        activeThreadID = nil
        activeThreadCreatedAt = nil
        activeThreadCustomTitle = nil
    }

    /// Wipe the whole archive, called when the user turns persistence off or taps Clear all.
    public func purgeAllConversations() {
        abortSessionWork()
        streamedAnswer = ""
        sessionBrief = ""
        lifecycle.clearPendingCapture()
        enqueueArchiveIO { archive in
            await archive.deleteAll()
        }
        resetConversation()
        _ = applyPhaseEvent(.deleteActiveThreadToIdle)
        archivePersistenceIssue = nil
    }

    /// Serializes archive read/write so delete/purge cannot race a late save.
    private func enqueueArchiveIO(_ operation: @escaping (ConversationArchiveStore) async -> Void) {
        guard let archive = conversationArchive else { return }
        let prior = archiveIOTask
        archiveIOTask = Task {
            _ = await prior?.value
            guard !Task.isCancelled else { return }
            await operation(archive)
            await MainActor.run { bumpArchiveRevision() }
        }
    }
}

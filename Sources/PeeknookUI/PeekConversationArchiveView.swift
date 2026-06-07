// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

/// Glass list/switcher for the opt-in conversation archive. Lists past chats (newest first),
/// opens one on tap, and deletes individually or all at once. Lives in the home column when idle;
/// rows reuse the command-bar glass language. Shown only when persistence is on and threads exist.
struct PeekConversationArchiveView: View {
    var orchestrator: SessionOrchestrator
    var onOpen: (ConversationSummary) -> Void
    var onClose: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var summaries: [ConversationSummary] = []
    @State private var pendingClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if summaries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(summaries) { summary in
                            ArchiveRow(
                                summary: summary,
                                onOpen: { open(summary) },
                                onDelete: { delete(summary) }
                            )
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .frame(maxHeight: PeekPanelLayout.conversationMaxHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: reload)
        .overlay {
            if pendingClearAll {
                PeekConfirmationOverlay(
                    title: "Clear all saved chats?",
                    message: "This permanently deletes every chat in your archive, screenshots included. You can't undo it.",
                    confirmTitle: "Clear all",
                    confirmSymbol: "trash",
                    onConfirm: clearAll,
                    onCancel: { pendingClearAll = false }
                )
            }
        }
        .animation(.easeOut(duration: 0.15), value: pendingClearAll)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
            Text(peek: "Past chats")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.primaryLabel)
            Spacer(minLength: 8)
            if !summaries.isEmpty {
                NookToolbarButton(
                    title: "Clear all",
                    symbol: "trash",
                    help: "Delete every saved chat"
                ) {
                    pendingClearAll = true
                }
            }
            NookToolbarButton(
                title: "Close",
                symbol: "xmark",
                help: "Back to home"
            ) {
                onClose()
            }
        }
    }

    private var emptyState: some View {
        Text(peek: "No saved chats yet. Finished chats are filed here while “Save conversations” is on.")
            .font(.system(size: 11))
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private func reload() {
        Task {
            summaries = await orchestrator.availableThreads()
        }
    }

    private func open(_ summary: ConversationSummary) {
        onOpen(summary)
    }

    private func delete(_ summary: ConversationSummary) {
        orchestrator.deleteThread(id: summary.id)
        withAnimation(.easeOut(duration: 0.18)) { reload() }
    }

    private func clearAll() {
        orchestrator.purgeAllConversations()
        pendingClearAll = false
        withAnimation(.easeOut(duration: 0.18)) { reload() }
        onClose()
    }
}

private struct ArchiveRow: View {
    let summary: ConversationSummary
    let onOpen: () -> Void
    let onDelete: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: summary.hasImage ? "photo" : "text.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.tertiaryLabel)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(summary.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.primaryLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(theme.tertiaryLabel)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryLabel)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Delete this chat")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .peekGlass(cornerRadius: 8, isHovered: isHovered)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private var subtitle: String {
        let when = ArchiveRow.relativeFormatter.localizedString(for: summary.updatedAt, relativeTo: Date())
        let turns = summary.turnCount == 1 ? "1 turn" : "\(summary.turnCount) turns"
        return "\(when) · \(turns)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

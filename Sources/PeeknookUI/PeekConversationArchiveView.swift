// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
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
                PeekFadedScrollView(maxHeight: PeekPanelLayout.conversationMaxHeight) {
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
                .peekDecorative()
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
                        .peekDecorative()
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
            .buttonStyle(.borderless)
            .peekAction(label: summary.title, hint: subtitle)

            ArchiveDeleteButton(action: onDelete)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .peekGlass(cornerRadius: 8, isHovered: isHovered)
        .onHover { isHovered = $0 }
        .animation(PeekHoverMotion.link.animation, value: isHovered)
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

private struct ArchiveDeleteButton: View {
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovered ? Color.red.opacity(0.95) : theme.tertiaryLabel)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.red.opacity(0.14) : .clear)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isHovered ? Color.red.opacity(0.28) : .clear, lineWidth: 0.5)
                }
        }
        .buttonStyle(.borderless)
        .peekHoverFeedback($isHovered, motion: .link)
        .animation(PeekHoverMotion.link.animation, value: isHovered)
        .help("Delete this chat")
        .peekAction(label: "Delete chat", hint: "Delete this chat")
    }
}

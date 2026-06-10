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
    @State private var searchQuery = ""
    @State private var pendingClearAll = false
    @State private var editingSummaryID: UUID?
    @State private var editingTitle = ""
    @FocusState private var renameFieldFocused: Bool

    private var filteredSummaries: [ConversationSummary] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return summaries }
        return summaries.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !summaries.isEmpty {
                searchField
            }
            if summaries.isEmpty {
                emptyState
            } else if filteredSummaries.isEmpty {
                noSearchResults
            } else {
                PeekFadedScrollView(maxHeight: PeekPanelLayout.conversationMaxHeight) {
                    VStack(spacing: 6) {
                        ForEach(filteredSummaries) { summary in
                            ArchiveRow(
                                summary: summary,
                                isEditing: editingSummaryID == summary.id,
                                editingTitle: editingBinding(for: summary),
                                renameFocused: $renameFieldFocused,
                                onOpen: { open(summary) },
                                onDelete: { delete(summary) },
                                onBeginRename: { beginRename(summary) },
                                onCommitRename: { commitRename(summary) },
                                onCancelRename: cancelRename
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: orchestrator.archiveRevision) {
            reload()
        }
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
        .animation(.easeOut(duration: 0.15), value: editingSummaryID)
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
                .peekDecorative()
            TextField("Search past chats", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(theme.primaryLabel)
                .accessibilityLabel(Text(peek: "Search past chats"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(theme.subtleFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.subtleStroke.opacity(0.3), lineWidth: 0.5)
        }
    }

    private var emptyState: some View {
        Text(peek: "No saved chats yet. Finished chats are filed here while “Save conversations” is on.")
            .font(.system(size: 11))
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private var noSearchResults: some View {
        Text(peek: "No chats match your search.")
            .font(.system(size: 11))
            .foregroundStyle(theme.tertiaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private func editingBinding(for summary: ConversationSummary) -> Binding<String> {
        Binding(
            get: { editingSummaryID == summary.id ? editingTitle : summary.title },
            set: { editingTitle = $0 }
        )
    }

    private func reload() {
        Task {
            summaries = await orchestrator.availableThreads()
        }
    }

    private func open(_ summary: ConversationSummary) {
        guard editingSummaryID == nil else { return }
        onOpen(summary)
    }

    private func delete(_ summary: ConversationSummary) {
        if editingSummaryID == summary.id { cancelRename() }
        orchestrator.deleteThread(id: summary.id)
        withAnimation(.easeOut(duration: 0.18)) { reload() }
    }

    private func beginRename(_ summary: ConversationSummary) {
        editingSummaryID = summary.id
        editingTitle = summary.title
        renameFieldFocused = true
    }

    private func commitRename(_ summary: ConversationSummary) {
        guard editingSummaryID == summary.id else { return }
        orchestrator.renameThread(id: summary.id, title: editingTitle)
        cancelRename()
    }

    private func cancelRename() {
        editingSummaryID = nil
        editingTitle = ""
        renameFieldFocused = false
    }

    private func clearAll() {
        orchestrator.purgeAllConversations()
        pendingClearAll = false
        searchQuery = ""
        cancelRename()
        withAnimation(.easeOut(duration: 0.18)) { reload() }
        onClose()
    }
}

private struct ArchiveRow: View {
    let summary: ConversationSummary
    let isEditing: Bool
    @Binding var editingTitle: String
    var renameFocused: FocusState<Bool>.Binding
    let onOpen: () -> Void
    let onDelete: () -> Void
    let onBeginRename: () -> Void
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

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
                        if isEditing {
                            TextField("Rename chat", text: $editingTitle)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.primaryLabel)
                                .focused(renameFocused)
                                .onSubmit(onCommitRename)
                                .accessibilityLabel(Text(peek: "Rename chat"))
                        } else {
                            Text(summary.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.primaryLabel)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
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
            .disabled(isEditing)
            .peekAction(label: summary.title, hint: subtitle)

            if isEditing {
                ArchiveCommitRenameButton(action: onCommitRename)
                ArchiveCancelRenameButton(action: onCancelRename)
            } else {
                ArchiveRenameButton(action: onBeginRename)
                ArchiveDeleteButton(action: onDelete)
            }
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

private struct ArchiveRenameButton: View {
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovered ? theme.primaryLabel : theme.tertiaryLabel)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? theme.subtleFill.opacity(0.55) : .clear)
                }
        }
        .buttonStyle(.borderless)
        .peekHoverFeedback($isHovered, motion: .link)
        .animation(PeekHoverMotion.link.animation, value: isHovered)
        .help("Rename this chat")
        .peekAction(label: "Rename chat", hint: "Rename this chat")
    }
}

private struct ArchiveCommitRenameButton: View {
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Color.green.opacity(0.95) : theme.tertiaryLabel)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? Color.green.opacity(0.14) : .clear)
                }
        }
        .buttonStyle(.borderless)
        .peekHoverFeedback($isHovered, motion: .link)
        .animation(PeekHoverMotion.link.animation, value: isHovered)
        .help("Save chat name")
        .peekAction(label: "Save chat name", hint: "Save chat name")
    }
}

private struct ArchiveCancelRenameButton: View {
    let action: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovered ? theme.primaryLabel : theme.tertiaryLabel)
                .frame(width: 22, height: 22)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isHovered ? theme.subtleFill.opacity(0.55) : .clear)
                }
        }
        .buttonStyle(.borderless)
        .peekHoverFeedback($isHovered, motion: .link)
        .animation(PeekHoverMotion.link.animation, value: isHovered)
        .help("Cancel rename")
        .peekAction(label: "Cancel rename", hint: "Cancel rename")
    }
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

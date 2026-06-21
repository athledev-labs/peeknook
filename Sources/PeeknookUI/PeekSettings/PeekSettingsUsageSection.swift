// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import PeeknookDesign
import SwiftUI

struct PeekSettingsDataSection: View {
    var orchestrator: SessionOrchestrator
    var storageFootprint: any StorageFootprinting
    var onReset: () -> Void
    var onOpenModelLibrary: () -> Void
    var onOpenPastChats: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var snapshot: StorageFootprintSnapshot?
    @State private var isLoadingFootprint = true
    @State private var showsResetConfirmation = false

    private static let archiveDiskCapLabel = "250 MB"
    private static let archiveThreadCap = ConversationArchiveStore.defaultMaxThreads

    private var refreshKey: String {
        "\(orchestrator.settings.persistConversation)|\(orchestrator.settings.ollamaBaseURL)"
    }

    private var persistenceEnabled: Bool {
        orchestrator.settings.persistConversation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            footprintSection

            PeekSettingsNote(text: "Activity charts and token history are in Stats on the home screen.")

            PeekSettingsCommandRow(
                icon: "arrow.counterclockwise",
                title: "Reset stats",
                subtitle: "Clear activity counters on this Mac",
                style: .destructive,
                trailing: .button("Reset"),
                action: { showsResetConfirmation = true }
            )
        }
        .confirmationDialog(
            "Reset usage stats?",
            isPresented: $showsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset stats", role: .destructive, action: onReset)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(peek: "Clears capture counts, token totals, and history on this Mac. You can't undo it.")
        }
        .task(id: refreshKey) {
            await refreshFootprint()
        }
    }

    @ViewBuilder
    private var footprintSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(peek: "Storage on this Mac")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)

            if isLoadingFootprint, snapshot == nil {
                footprintLoadingPlaceholder
            } else if let snapshot {
                peeknookArchiveGroup(snapshot.archive)
                ollamaGroup(snapshot.ollamaDisk, memory: snapshot.ollamaMemory)
                thisMacGroup(snapshot)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(peek: "Storage on this Mac"))
    }

    private var footprintLoadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.subtleFill.opacity(0.45))
                .frame(height: 28)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.subtleFill.opacity(0.35))
                .frame(height: 28)
        }
        .peekLoading("Loading storage summary")
    }

    @ViewBuilder
    private func peeknookArchiveGroup(_ state: ArchiveFootprintState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PeekSettingsFootprintGroupHeader(title: "Peeknook archive")

            switch state {
            case .disabled:
                PeekSettingsFootprintRow(
                    icon: "tray",
                    title: "Saved chats",
                    detail: "Off. Turn on Save conversations in Capture to keep chats and screenshots on this Mac.",
                    value: "Off"
                )
            case .empty:
                PeekSettingsFootprintRow(
                    icon: "tray",
                    title: "Saved chats",
                    detail: "No saved chats yet. Done keeps a chat; New chat deletes it.",
                    value: "0 saved chats"
                )
                pastChatsLink
            case .unavailable(let reason):
                PeekSettingsFootprintRow(
                    icon: "tray",
                    title: "Saved chats",
                    detail: reason,
                    value: "Unavailable",
                    tone: .warning
                )
            case .inUse(let footprint):
                PeekSettingsFootprintRow(
                    icon: "tray.full",
                    title: "Saved chats",
                    detail: "Up to \(Self.archiveThreadCap) chats on this Mac",
                    value: savedChatCountLabel(footprint.threadCount)
                )
                PeekSettingsFootprintProgressRow(
                    icon: "internaldrive",
                    title: "Disk use",
                    detail: "\(ByteFormat.storage(footprint.usedBytes)) of \(Self.archiveDiskCapLabel) used",
                    fraction: footprint.byteFraction,
                    accessibilityLabel: "Archive disk use, \(ByteFormat.storage(footprint.usedBytes)) of \(Self.archiveDiskCapLabel)"
                )
                PeekSettingsNote(
                    text: "Oldest chats are removed automatically at \(Self.archiveThreadCap) chats or \(Self.archiveDiskCapLabel)."
                )
                pastChatsLink
            }
        }
    }

    @ViewBuilder
    private var pastChatsLink: some View {
        if persistenceEnabled {
            PeekSettingsCommandRow(
                icon: "clock.arrow.circlepath",
                title: "Past chats",
                subtitle: "Open, resume, or delete saved chats",
                trailing: .chevron,
                action: onOpenPastChats
            )
            .peekAction(label: "Past chats", hint: "Opens the saved chat list on the home screen")
        }
    }

    @ViewBuilder
    private func ollamaGroup(_ disk: OllamaFootprintState, memory: OllamaMemoryFootprintState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PeekSettingsFootprintGroupHeader(title: "Ollama")

            ollamaDiskRow(disk)
            ollamaMemoryRow(memory)
        }
    }

    @ViewBuilder
    private func ollamaDiskRow(_ state: OllamaFootprintState) -> some View {
        switch state {
        case .local(let disk):
            let total = ByteFormat.storage(disk.totalBytes)
            let modelLabel = disk.modelCount == 1 ? "1 model" : "\(disk.modelCount) models"
            PeekSettingsCommandRow(
                icon: "externaldrive",
                title: "Models on disk",
                subtitle: "\(modelLabel) downloaded · \(total) total",
                trailing: .chevron,
                action: onOpenModelLibrary
            )
            .peekAction(label: "Models on disk", hint: "Opens model library for per-model details")
        case .unavailable(let reason):
            PeekSettingsFootprintRow(
                icon: "externaldrive",
                title: "Models on disk",
                detail: reason,
                value: "Unavailable",
                tone: .warning
            )
        }
    }

    @ViewBuilder
    private func ollamaMemoryRow(_ state: OllamaMemoryFootprintState) -> some View {
        switch state {
        case .noneLoaded:
            ollamaMemoryNoneRow()
        case .unavailable(let reason):
            PeekSettingsFootprintRow(
                icon: "memorychip",
                title: "Loaded in Ollama",
                detail: reason,
                value: "Unavailable",
                tone: .warning
            )
        case .loaded(let models):
            if let primary = models.first {
                let ram = ByteFormat.storage(primary.sizeBytes)
                let extra = models.count > 1 ? " +\(models.count - 1) more" : ""
                PeekSettingsFootprintRow(
                    icon: "memorychip",
                    title: "Loaded in Ollama",
                    detail: "\(primary.name)\(extra): weights Ollama is holding in memory after a capture",
                    value: ram
                )
            } else {
                ollamaMemoryNoneRow()
            }
        }
    }

    private func ollamaMemoryNoneRow() -> some View {
        PeekSettingsFootprintRow(
            icon: "memorychip",
            title: "Loaded in Ollama",
            detail: "Nothing loaded right now. Ollama loads a model when you capture.",
            value: "None"
        )
    }

    private func thisMacGroup(_ snapshot: StorageFootprintSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PeekSettingsFootprintGroupHeader(title: "This Mac")

            PeekSettingsFootprintRow(
                icon: "memorychip",
                title: "Installed RAM",
                detail: "Total memory on this Mac",
                value: "\(snapshot.systemMemoryGB) GB"
            )
            PeekSettingsFootprintRow(
                icon: "sparkles",
                title: "Recommended model",
                detail: "Based on total RAM; does not account for other open apps",
                value: snapshot.suggestedTextModel
            )
        }
    }

    private func savedChatCountLabel(_ count: Int) -> String {
        count == 1 ? "1 saved chat" : "\(count) saved chats"
    }

    private func refreshFootprint() async {
        isLoadingFootprint = true
        let next = await storageFootprint.snapshot(
            persistConversation: orchestrator.settings.persistConversation,
            ollamaBaseURL: orchestrator.settings.ollamaBaseURL,
            acceptInsecureRemoteOllama: orchestrator.settings.acceptInsecureRemoteOllama
        )
        snapshot = next
        isLoadingFootprint = false
    }
}

private struct PeekSettingsFootprintGroupHeader: View {
    let title: String

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        Text(peek: title)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(theme.tertiaryLabel)
            .textCase(.uppercase)
            .tracking(0.35)
            .padding(.top, 2)
    }
}

private enum PeekSettingsFootprintTone {
    case standard
    case warning
}

private struct PeekSettingsFootprintRow: View {
    let icon: String
    let title: String
    let detail: String
    let value: String
    var tone: PeekSettingsFootprintTone = .standard

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tone == .warning ? Color.orange.opacity(0.9) : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)
                .peekDecorative()

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: detail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(tone == .warning ? Color.orange.opacity(0.9) : theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Text(peek: value)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.secondaryLabel)
                .multilineTextAlignment(.trailing)
                .frame(width: PeekSettingsRowMetrics.trailingColumnWidth, alignment: .trailing)
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
        .accessibilityElement(children: .combine)
    }
}

private struct PeekSettingsFootprintProgressRow: View {
    let icon: String
    let title: String
    let detail: String
    let fraction: Double
    let accessibilityLabel: String

    @Environment(\.nookResolvedTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: PeekSettingsRowMetrics.rowSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                    .peekDecorative()

                VStack(alignment: .leading, spacing: 2) {
                    Text(peek: title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.primaryLabel.opacity(0.95))
                    Text(peek: detail)
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ProgressView(value: min(1, max(0, fraction)))
                .progressViewStyle(.linear)
                .tint(fraction >= 0.8 ? Color.orange : theme.accent)
                .padding(.leading, PeekSettingsRowMetrics.iconWidth + PeekSettingsRowMetrics.rowSpacing)
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(peek: accessibilityLabel))
        .accessibilityValue(Text(verbatim: "\(Int((fraction * 100).rounded())) percent of cap"))
    }
}

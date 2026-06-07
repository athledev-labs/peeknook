// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore
import SwiftUI

struct PeekSettingsVisionSection: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    var ollamaStatusLabel: String
    var ollamaStatusDetail: String?
    var ollamaStatusTone: PeekSettingsStatusTone
    @Binding var advancedExpanded: Bool
    var onSelectModel: (InferenceModelOption) -> Void
    var onBrowseModels: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var visionSupport: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.green)
                    .frame(width: 18)
                Text("100% local — nothing leaves this Mac")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.secondaryLabel)
            }
            .padding(.vertical, 2)

            PeekSettingsStatusRow(
                icon: ollamaStatusTone.icon,
                title: "Ollama server",
                detail: ollamaServerDetail,
                status: ollamaStatusLabel,
                tone: ollamaStatusTone
            )

            PeekSettingsModelPickerRow(
                currentTag: orchestrator.settings.textModel,
                recommendedTag: SystemProfile.current().suggestedTextModel,
                models: settings.availableModels,
                customModels: settings.customModels,
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: onSelectModel,
                onBrowseModels: onBrowseModels
            )

            if visionSupport == false {
                PeekSettingsNote(
                    text: "⚠︎ This model can’t see your screen. Peeknook sends a screenshot with every capture, so a text-only model will ignore the image. Pick a vision model (like Gemma 4) for screen capture."
                )
            }

            PeekSettingsCommandRow(
                icon: "square.grid.2x2",
                title: "Manage models",
                subtitle: "Browse, download, and switch vision models",
                trailing: .chevron,
                action: onBrowseModels
            )

            if setup.isPullingModel {
                // Same pull task as Setup — expose Cancel here for symmetric UX.
                PeekSettingsCommandRow(
                    icon: "arrow.down.circle",
                    title: downloadRowTitle,
                    subtitle: downloadRowSubtitle,
                    style: .destructive,
                    trailing: .button("Cancel"),
                    action: { setup.cancelPull() }
                )
            } else if selectedModelNeedsDownload {
                PeekSettingsCommandRow(
                    icon: "arrow.down.circle",
                    title: downloadRowTitle,
                    subtitle: downloadRowSubtitle,
                    trailing: .button("Download"),
                    action: { settings.beginModelDownloadForCurrentSelection() }
                )
            }

            PeekSettingsExpandableRow(
                icon: "gearshape",
                title: "Advanced",
                subtitle: "Custom server address",
                isExpanded: $advancedExpanded
            )

            if advancedExpanded {
                PeekSettingsFormField(
                    icon: "link",
                    title: "Server address",
                    text: ollamaURLBinding,
                    placeholder: "http://127.0.0.1:11434",
                    monospaced: true
                )
                PeekSettingsNote(
                    text: "Default is this Mac. Change only if Ollama runs elsewhere."
                )
            }
        }
        .task(id: visionCheckKey) {
            visionSupport = await settings.currentModelSupportsVision()
        }
    }

    /// Re-check vision support whenever the model or server changes.
    private var visionCheckKey: String {
        "\(orchestrator.settings.textModel)|\(orchestrator.settings.ollamaBaseURL)"
    }

    private var ollamaServerDetail: String? {
        if let ollamaStatusDetail { return ollamaStatusDetail }
        switch ollamaStatusTone {
        case .loading: return "Checking connection…"
        case .ready: return "Runs vision models on this Mac"
        case .warning, .error: return nil
        }
    }

    private var selectedModelNeedsDownload: Bool {
        !setup.isModelInstalled(orchestrator.settings.textModel)
    }

    private var selectedModelOption: InferenceModelOption? {
        TextModelCatalog.option(for: orchestrator.settings.textModel)
    }

    private var downloadRowTitle: String {
        let name = TextModelCatalog.displayName(for: orchestrator.settings.textModel, custom: settings.customModels)
        return setup.isPullingModel ? "Downloading \(name)" : "Download \(name)"
    }

    private var downloadRowSubtitle: String {
        if setup.isPullingModel {
            return setup.pullStatusLine ?? "Download in progress…"
        }
        if let option = selectedModelOption {
            return option.downloadRowSubtitle
        }
        return setup.suggestedModelDiskHint + " · once via Ollama"
    }

    private var ollamaURLBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.ollamaBaseURL },
            set: { settings.setOllamaBaseURL($0) }
        )
    }
}

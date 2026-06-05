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

    @Environment(\.nookResolvedTheme) private var theme

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
                isInstalled: { setup.isModelInstalled($0) },
                onSelect: onSelectModel
            )

            if selectedModelNeedsDownload || setup.isPullingModel {
                PeekSettingsCommandRow(
                    icon: "arrow.down.circle",
                    title: downloadRowTitle,
                    subtitle: downloadRowSubtitle,
                    trailing: .button(setup.isPullingModel ? "Downloading…" : "Download"),
                    action: { settings.beginModelDownloadForCurrentSelection() }
                )
                .disabled(setup.isPullingModel)
                .opacity(setup.isPullingModel ? 0.55 : 1)
            }

            if let pullStatusLine = setup.pullStatusLine, setup.isPullingModel {
                Text(pullStatusLine)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .lineLimit(2)
                    .padding(.leading, PeekSettingsRowMetrics.iconWidth + PeekSettingsRowMetrics.rowSpacing)
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
        "Download \(TextModelCatalog.displayName(for: orchestrator.settings.textModel))"
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

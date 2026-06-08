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
            privacyBanner

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
                // Same pull task as Setup, expose Cancel here for symmetric UX.
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
                    placeholder: orchestrator.settings.usesRemoteOllama
                        ? "https://your-server:11434"
                        : "http://127.0.0.1:11434",
                    monospaced: true
                )
                if orchestrator.settings.remoteOllamaUsesInsecureHTTP {
                    PeekSettingsNote(
                        text: "Remote servers must use HTTPS, or enable “Allow insecure HTTP” below."
                    )
                }
                if orchestrator.settings.usesRemoteOllama {
                    PeekSettingsToggleRow(
                        icon: orchestrator.settings.acceptInsecureRemoteOllama
                            ? "lock.open.fill" : "lock.shield",
                        title: "Allow insecure HTTP",
                        detail: "Send screenshots to a remote Ollama server without TLS (not recommended)",
                        isOn: acceptInsecureRemoteBinding
                    )
                }
                PeekSettingsNote(
                    text: "Default is this Mac. Change only if Ollama runs elsewhere."
                )
            }
        }
        .task(id: visionCheckKey) {
            visionSupport = await settings.currentModelSupportsVision()
        }
    }

    private var privacyBanner: some View {
        let webLookup = orchestrator.settings.webLookupEnabled
        let remoteOllama = orchestrator.settings.usesRemoteOllama
        let insecureRemote = orchestrator.settings.remoteOllamaUsesInsecureHTTP
            || (remoteOllama && orchestrator.settings.acceptInsecureRemoteOllama)
        let icon = webLookup ? "globe.americas.fill" : (remoteOllama ? "point.3.connected.trianglepath.dotted" : "lock.fill")
        let tint: Color = webLookup ? .orange : (insecureRemote ? .orange : (remoteOllama ? theme.accent : .green))
        let message: String = {
            if webLookup && remoteOllama {
                return "Ollama runs elsewhere; web lookup sends search queries to DuckDuckGo."
            }
            if webLookup {
                return "Answers stay local; web lookup sends search queries to DuckDuckGo."
            }
            if remoteOllama && orchestrator.settings.acceptInsecureRemoteOllama {
                return "Screenshots go to your Ollama server without encryption (HTTP)."
            }
            if insecureRemote {
                return "Remote Ollama must use HTTPS. Update the server address in Advanced."
            }
            if remoteOllama {
                return "Screenshots and answers go to your Ollama server. :cloud model tags may run on Ollama's cloud infrastructure."
            }
            return "Capture and answers run on this Mac via Ollama."
        }()
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            Text(message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    /// Re-check vision support whenever the model or server changes.
    private var visionCheckKey: String {
        "\(orchestrator.settings.textModel)|\(orchestrator.settings.ollamaBaseURL)"
    }

    private var ollamaServerDetail: String? {
        if let ollamaStatusDetail { return ollamaStatusDetail }
        switch ollamaStatusTone {
        case .loading: return "Checking connection…"
        case .ready:
            return orchestrator.settings.usesRemoteOllama
                ? "Connected to your Ollama server"
                : "Runs vision models on this Mac"
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

    private var acceptInsecureRemoteBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.acceptInsecureRemoteOllama },
            set: { settings.setAcceptInsecureRemoteOllama($0) }
        )
    }
}

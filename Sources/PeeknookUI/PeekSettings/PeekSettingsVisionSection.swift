// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

struct PeekSettingsVisionSection: View {
    var orchestrator: SessionOrchestrator
    var setup: SetupCoordinator
    var settings: PeekSettingsController
    var modelCatalog: ModelCatalogService
    var ollamaStatusLabel: String
    var ollamaStatusDetail: String?
    var ollamaStatusTone: PeekSettingsStatusTone
    @Binding var advancedExpanded: Bool
    var onSelectModel: (InferenceModelOption) -> Void
    var onBrowseModels: () -> Void

    @Environment(\.nookResolvedTheme) private var theme
    @State private var visionSupport: Bool?
    @State private var apiKeyDraft = ""
    @State private var apiKeyIsSet = false
    @State private var servedModels: [String] = []

    private var isOpenAICompatible: Bool {
        orchestrator.settings.answerBackend == .openAICompatible
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            privacyBanner

            backendPickerRow

            if isOpenAICompatible {
                openAICompatibleContent
            } else {
                ollamaContent
            }

            fastFollowUpsBlock
        }
        .task(id: visionCheckKey) {
            visionSupport = await settings.currentModelSupportsVision()
        }
        .task(id: servedModelsKey) {
            apiKeyIsSet = settings.openAICompatibleKeyIsSet
            guard isOpenAICompatible,
                  !orchestrator.settings.openAICompatibleBaseURL.isEmpty else {
                servedModels = []
                return
            }
            servedModels = await settings.openAICompatibleServedModels()
        }
    }

    // MARK: - Fast follow-ups (text-only routing)

    /// Opt-in routing of pure text follow-ups to a smaller model on the active backend. The new
    /// capture path is untouched — only follow-ups that carry no new screenshot are affected, and the
    /// screenshot is dropped for those (the explicit speed trade, stated in the toggle copy).
    @ViewBuilder
    private var fastFollowUpsBlock: some View {
        Divider().padding(.vertical, 2)

        PeekSettingsToggleRow(
            icon: "hare",
            title: "Fast follow-ups",
            detail: "Answer text-only follow-ups with a smaller, faster model, without re-sending the screenshot. New captures always use your vision model.",
            isOn: fastTextFollowUpsBinding
        )

        if orchestrator.settings.fastTextFollowUps {
            followUpModelPickerRow
            if !orchestrator.settings.hasUsableTextOnlyModel {
                PeekSettingsNote(text: "Choose a follow-up model to turn this on.")
            }
        }
    }

    private var followUpModelPickerRow: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "hare")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: "Follow-up model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: "A smaller model for text-only follow-ups")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ValueDropdownPill(
                symbol: "hare",
                title: orchestrator.settings.textOnlyModelTag.isEmpty
                    ? PeekLocalized("Choose model")
                    : orchestrator.settings.textOnlyModelTag,
                help: "Follow-up model"
            ) { close in
                PeekPreflightMenuContent.visionModelHomeMenu(
                    models: followUpModelOptions,
                    isInstalled: { isOpenAICompatible ? true : setup.isModelInstalled($0) },
                    isSelected: { modelCatalog.isSameModel($0.tag, orchestrator.settings.textOnlyModelTag) },
                    onSelect: { selectFollowUpModel($0) },
                    onBrowseModels: nil,
                    close: close
                )
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    /// Models for the follow-up picker come from the active backend (Ollama catalog or the server's
    /// served list), so the chosen tag always rides the configured endpoint — no empty-server route.
    private var followUpModelOptions: [InferenceModelOption] {
        settings.pickerModels(servedOpenAIModels: servedModels)
    }

    /// Bind the follow-up model to the backend it was picked from, so model and endpoint always agree.
    private func selectFollowUpModel(_ option: InferenceModelOption) {
        settings.setTextOnlyBackend(orchestrator.settings.answerBackend)
        settings.setTextOnlyModelTag(option.tag)
    }

    private var fastTextFollowUpsBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.fastTextFollowUps },
            set: { settings.setFastTextFollowUps($0) }
        )
    }

    // MARK: - Backend picker

    private var backendPickerRow: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "server.rack")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: "Backend")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: backendDetail)
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // One pill per case: a future backend auto-appears here, no layout change.
            HStack(spacing: 4) {
                ForEach(InferenceBackend.allCases, id: \.self) { backend in
                    PeekSurfaceFilterPill(
                        title: backend.providerLabel,
                        isSelected: orchestrator.settings.answerBackend == backend,
                        hint: "Select inference backend",
                        action: { settings.setAnswerBackend(backend) }
                    )
                }
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    private var backendDetail: String {
        isOpenAICompatible
            ? "Local OpenAI-compatible server (LM Studio, vLLM). Loads its own model."
            : "Local Ollama (default). Manages model downloads for you."
    }

    // MARK: - Ollama backend rows (today's section, unchanged)

    @ViewBuilder
    private var ollamaContent: some View {
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
            isSelected: { modelCatalog.matchesModel(installedNames: [orchestrator.settings.textModel], wanted: $0.tag) },
            onSelect: onSelectModel,
            onBrowseModels: onBrowseModels
        )

        if visionSupport == false {
            PeekSettingsNote(
                text: "⚠︎ This model can’t see your screen. Peeknook sends a screenshot with every capture, so a text-only model will ignore the image. Pick a vision model for screen capture."
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

    // MARK: - OpenAI-compatible backend rows

    @ViewBuilder
    private var openAICompatibleContent: some View {
        PeekSettingsStatusRow(
            icon: ollamaStatusTone.icon,
            title: "Inference server",
            detail: openAIServerDetail,
            status: ollamaStatusLabel,
            tone: ollamaStatusTone
        )

        PeekSettingsFormField(
            icon: "link",
            title: "Server address",
            text: openAIURLBinding,
            placeholder: "http://127.0.0.1:1234",
            monospaced: true
        )
        if orchestrator.settings.openAICompatibleUsesInsecureHTTP {
            PeekSettingsNote(
                text: "Remote servers must use HTTPS, or enable “Allow insecure HTTP” below."
            )
        }
        if orchestrator.settings.openAICompatibleUsesRemoteHost {
            PeekSettingsToggleRow(
                icon: orchestrator.settings.acceptInsecureRemoteOpenAICompatible
                    ? "lock.open.fill" : "lock.shield",
                title: "Allow insecure HTTP",
                detail: "Send screenshots to a remote server without TLS (not recommended)",
                isOn: acceptInsecureOpenAIBinding
            )
        }

        // Write-only: commits to the Keychain on Return and never echoes the stored key back.
        PeekSettingsFormField(
            icon: "key",
            title: apiKeyIsSet ? "API key (saved, enter a new key to replace)" : "API key (optional)",
            text: $apiKeyDraft,
            placeholder: "Leave blank for local servers",
            secure: true,
            onSubmit: {
                guard !apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                if settings.setOpenAICompatibleAPIKey(apiKeyDraft) {
                    apiKeyDraft = ""
                    apiKeyIsSet = settings.openAICompatibleKeyIsSet
                }
            }
        )
        if apiKeyIsSet {
            PeekSettingsCommandRow(
                icon: "key.slash",
                title: "Clear API key",
                subtitle: "Removes the stored key from the Keychain",
                style: .destructive,
                trailing: .button("Clear"),
                action: {
                    if settings.setOpenAICompatibleAPIKey("") {
                        apiKeyIsSet = settings.openAICompatibleKeyIsSet
                    }
                }
            )
        }

        servedModelPickerRow

        if servedModels.isEmpty, !orchestrator.settings.openAICompatibleBaseURL.isEmpty {
            PeekSettingsNote(
                text: "No models found on the server. Start your OpenAI-compatible server and load a model."
            )
        }
        if visionSupport == nil, !orchestrator.settings.openAICompatibleModelTag.isEmpty {
            PeekSettingsNote(
                text: "Peeknook can’t verify vision support on this server. If the model is multimodal, screen capture works; if not, the screenshot is ignored."
            )
        }
    }

    private var servedModelPickerRow: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: "Answer model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: "Served by your inference server")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            ValueDropdownPill(
                symbol: "cpu",
                title: orchestrator.settings.openAICompatibleModelTag.isEmpty
                    ? PeekLocalized("Choose model")
                    : orchestrator.settings.openAICompatibleModelTag,
                help: "Answer model"
            ) { close in
                PeekPreflightMenuContent.visionModelHomeMenu(
                    models: servedModelOptions,
                    isInstalled: { _ in true },   // server-loaded: no download state
                    isSelected: {
                        modelCatalog.isSameModel($0.tag, orchestrator.settings.openAICompatibleModelTag)
                    },
                    onSelect: { _ = settings.pickModel($0) },
                    onBrowseModels: nil,          // the library browses the Ollama catalog
                    close: close
                )
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    private var servedModelOptions: [InferenceModelOption] {
        servedModels.map {
            InferenceModelOption(
                tag: $0,
                displayName: $0,
                provider: InferenceBackend.openAICompatible.providerLabel
            )
        }
    }

    private var openAIServerDetail: String? {
        if orchestrator.settings.openAICompatibleBaseURL.isEmpty {
            return "Enter your server address below"
        }
        if let ollamaStatusDetail { return ollamaStatusDetail }
        switch ollamaStatusTone {
        case .loading: return "Checking connection…"
        case .ready: return "Connected to your inference server"
        case .warning, .error: return nil
        }
    }

    /// Refetch the served-model list when the backend, server, or stored key changes.
    private var servedModelsKey: String {
        "\(orchestrator.settings.answerBackend.rawValue)|\(orchestrator.settings.openAICompatibleBaseURL)|\(orchestrator.settings.acceptInsecureRemoteOpenAICompatible)"
    }

    private var openAIURLBinding: Binding<String> {
        Binding(
            get: { orchestrator.settings.openAICompatibleBaseURL },
            set: { settings.setOpenAICompatibleBaseURL($0) }
        )
    }

    private var acceptInsecureOpenAIBinding: Binding<Bool> {
        Binding(
            get: { orchestrator.settings.acceptInsecureRemoteOpenAICompatible },
            set: { settings.setAcceptInsecureRemoteOpenAICompatible($0) }
        )
    }

    private var privacyBanner: some View {
        let webLookup = orchestrator.settings.webLookupEnabled
        let remoteServer = isOpenAICompatible
            ? orchestrator.settings.openAICompatibleUsesRemoteHost
            : orchestrator.settings.usesRemoteOllama
        let insecureRemote = isOpenAICompatible
            ? (orchestrator.settings.openAICompatibleUsesInsecureHTTP
                || (remoteServer && orchestrator.settings.acceptInsecureRemoteOpenAICompatible))
            : (orchestrator.settings.remoteOllamaUsesInsecureHTTP
                || (remoteServer && orchestrator.settings.acceptInsecureRemoteOllama))
        let serverName = isOpenAICompatible ? "inference server" : "Ollama server"
        let icon = webLookup ? "globe.americas.fill" : (remoteServer ? "point.3.connected.trianglepath.dotted" : "lock.fill")
        let tint: Color = webLookup ? .orange : (insecureRemote ? .orange : (remoteServer ? theme.accent : .green))
        let message: String = {
            if webLookup && remoteServer {
                return "Your \(serverName) runs elsewhere; web lookup sends search queries to DuckDuckGo."
            }
            if webLookup {
                return "Answers stay local; web lookup sends search queries to DuckDuckGo."
            }
            if remoteServer && insecureRemote {
                return "Screenshots go to your \(serverName) without encryption (HTTP)."
            }
            if remoteServer {
                if isOpenAICompatible {
                    return "Screenshots and answers go to your inference server."
                }
                return "Screenshots and answers go to your Ollama server. :cloud model tags may run on Ollama's cloud infrastructure."
            }
            if isOpenAICompatible {
                return "Capture and answers run on this Mac via your OpenAI-compatible server."
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

    /// Re-check vision support whenever the backend, model, or server changes.
    private var visionCheckKey: String {
        "\(orchestrator.settings.answerBackend.rawValue)|\(orchestrator.settings.answerModel.tag)|\(orchestrator.settings.activeEndpoint.connection.baseURL)"
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

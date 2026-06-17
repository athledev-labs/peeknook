// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Inline editor for one user profile: name, standing instruction, answer-model binding, and the
/// five module overrides. Reads/writes through `ProfileStore` directly (every set persists).
struct PeekProfileEditor: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController
    var store: ProfileStore
    var profileID: String

    @Environment(\.nookResolvedTheme) private var theme
    @State private var instructionDraft = ""
    @State private var templateDraft = ""
    @State private var didLoadDraft = false
    @State private var servedModels: [String] = []

    private var profile: GroundProfile { store.profile(id: profileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsFormField(
                icon: "character.cursor.ibeam",
                title: "Name",
                text: nameBinding,
                placeholder: "My profile"
            )

            instructionField

            groundsField

            templateField

            modelBindingRow

            moduleOverrideRows
        }
        .padding(.vertical, 4)
        .task(id: profileID) {
            instructionDraft = profile.instruction ?? ""
            templateDraft = profile.promptTemplate ?? ""
            didLoadDraft = true
            if orchestrator.settings.answerBackend == .openAICompatible {
                servedModels = await settings.openAICompatibleServedModels()
            }
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { profile.displayName ?? "" },
            set: { store.rename(id: profileID, to: $0) }
        )
    }

    // MARK: - Instruction

    private var instructionField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                Text(peek: "Instruction")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            // Self-bounded height (invariant: growable views cap themselves in the notch).
            TextEditor(text: instructionBinding)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: 44, maxHeight: 96)
                .background(theme.subtleFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.subtleStroke.opacity(0.3), lineWidth: 1)
                )
                .accessibilityLabel(Text(peek: "Profile instruction"))
            PeekSettingsNote(
                text: "Standing guidance for every answer in this profile — e.g. “You are a patient chess coach.”"
            )
        }
    }

    private var instructionBinding: Binding<String> {
        Binding(
            get: { instructionDraft },
            set: { newValue in
                instructionDraft = String(newValue.prefix(ProfileInstruction.maxLength))
                guard didLoadDraft else { return }
                store.setInstruction(id: profileID, instructionDraft)
            }
        )
    }

    // MARK: - Grounds

    /// The grounds this profile captures, offered only over ``Ground/multiGroundEligible``. The
    /// primary ground is always on and cannot be removed (the store re-inserts it anyway). The
    /// system-audio ground is gated on the "Hear system audio" opt-in: when that is off the pill is
    /// disabled with a hint, so a user sees why a profile carrying audio still only reads the screen.
    private var groundsField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                Text(peek: "What it captures")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            PeekWrappingPills {
                ForEach(eligibleGrounds, id: \.self) { ground in
                    groundPill(ground)
                }
            }
            if !orchestrator.settings.systemAudioEnabled {
                PeekSettingsNote(
                    text: "Turn on Hear system audio in Capture to let a profile transcribe what is playing."
                )
            } else {
                PeekSettingsNote(text: "Each selected ground is captured and folded into one question.")
            }
        }
    }

    /// Eligible grounds in a stable display order (primary first).
    private var eligibleGrounds: [Ground] {
        let primary = profile.primaryGround
        let rest = [Ground.screen, .selectedText, .systemAudio, .clipboard, .accessibilityTree]
            .filter { Ground.multiGroundEligible.contains($0) && $0 != primary }
        return [primary] + rest
    }

    @ViewBuilder
    private func groundPill(_ ground: Ground) -> some View {
        let isPrimary = ground == profile.primaryGround
        let gated = isGated(ground)
        let selected = profile.activeGrounds.contains(ground)
        PeekSurfaceFilterPill(
            title: groundTitle(ground),
            isSelected: selected,
            hint: groundHint(ground, isPrimary: isPrimary, gated: gated),
            action: { toggleGround(ground, currentlySelected: selected) }
        )
        // The primary ground is part of the profile's identity; an opt-in ground is unavailable until
        // its opt-in is on.
        .disabled(isPrimary || gated)
    }

    /// A ground whose capture is held behind an off-by-default opt-in is gated (disabled with a hint)
    /// until that opt-in is on, so a user sees why a profile carrying it still only reads its other legs.
    private func isGated(_ ground: Ground) -> Bool {
        switch ground {
        case .systemAudio: return !orchestrator.settings.systemAudioEnabled
        case .accessibilityTree: return !orchestrator.settings.accessibilityTreeEnabled
        default: return false
        }
    }

    private func toggleGround(_ ground: Ground, currentlySelected: Bool) {
        var grounds = profile.activeGrounds
        if currentlySelected {
            grounds.remove(ground)
        } else {
            grounds.insert(ground)
        }
        // The store sanitizes to the eligible set and always re-inserts the primary ground.
        store.setActiveGrounds(grounds, for: profileID)
    }

    /// Raw catalog KEYS — ``PeekSurfaceFilterPill`` localizes the title/hint itself (via `Text(peek:)`
    /// and `peekAction`), matching every other filter-pill caller.
    private func groundTitle(_ ground: Ground) -> String {
        switch ground {
        case .screen: "Screen"
        case .selectedText: "Selected text"
        case .systemAudio: "System audio"
        case .clipboard: "Clipboard"
        case .accessibilityTree: "Accessibility tree"
        default: "Screen"
        }
    }

    private func groundHint(_ ground: Ground, isPrimary: Bool, gated: Bool) -> String {
        if isPrimary {
            return "Always captured by this profile"
        }
        if gated {
            switch ground {
            case .systemAudio: return "Turn on Hear system audio in Capture first"
            case .accessibilityTree: return "Turn on Read accessibility tree in Capture first"
            default: break
            }
        }
        if ground == .accessibilityTree {
            return "On-device window structure (roles, labels, values), not a screenshot. Secure fields are redacted."
        }
        return "Include this ground in every capture"
    }

    // MARK: - Prompt template

    private var templateField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "doc.plaintext")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                Text(peek: "Prompt template")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            // Self-bounded height (invariant: growable views cap themselves in the notch).
            TextEditor(text: templateBinding)
                .font(.system(size: 11))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(minHeight: 44, maxHeight: 120)
                .background(theme.subtleFill.opacity(0.45), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(theme.subtleStroke.opacity(0.3), lineWidth: 1)
                )
                .accessibilityLabel(Text(peek: "Profile prompt template"))
            PeekSettingsNote(
                text: "Optional format and ground rules folded into the prompt — e.g. “Answer in three bullet points.”"
            )
        }
    }

    private var templateBinding: Binding<String> {
        Binding(
            get: { templateDraft },
            set: { newValue in
                templateDraft = String(newValue.prefix(ProfileTemplate.maxLength))
                guard didLoadDraft else { return }
                store.setPromptTemplate(id: profileID, templateDraft)
            }
        )
    }

    // MARK: - Model binding

    private var modelBindingRow: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: "Answer model")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: "Global by default; bind one for this profile")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            Spacer(minLength: 8)

            ValueDropdownPill(symbol: "cpu", title: bindingLabel, help: "Answer model") { close in
                bindingMenu(close: close)
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    private var bindingLabel: String {
        guard let binding = profile.modelBinding, binding.hasUsableTag else {
            return PeekLocalized("Global")
        }
        return TextModelCatalog.displayName(for: binding.tag, custom: settings.customModels)
    }

    /// "Use global model" + the global backend's tags, bound to that backend (so the endpoint
    /// always derives from the binding's own backend). Per-profile servers/keys stay reserved.
    @ViewBuilder
    private func bindingMenu(close: @escaping () -> Void) -> some View {
        Button {
            store.setModelBinding(id: profileID, nil)
            close()
        } label: {
            ValueMenuRow(
                title: PeekLocalized("Use global model"),
                subtitle: TextModelCatalog.displayName(
                    for: orchestrator.settings.answerModel.tag, custom: settings.customModels
                ),
                selected: !(profile.modelBinding?.hasUsableTag ?? false)
            )
        }
        .buttonStyle(.plain)

        Divider().padding(.vertical, 2)

        PeekPreflightMenuContent.visionModelHomeMenu(
            models: bindableOptions,
            isInstalled: { backend == .ollama ? orchestrator.setup?.isModelInstalled($0) ?? true : true },
            isSelected: { option in
                guard let binding = profile.modelBinding, binding.hasUsableTag else { return false }
                return binding.backend == backend && ModelTag.isSame(binding.tag, option.tag)
            },
            onSelect: { option in
                store.setModelBinding(
                    id: profileID,
                    ProfileModelBinding(backend: backend, normalizingTag: option.tag)
                )
            },
            onBrowseModels: nil,
            close: close
        )
    }

    private var backend: InferenceBackend { orchestrator.settings.answerBackend }

    private var bindableOptions: [InferenceModelOption] {
        switch backend {
        case .ollama:
            return settings.availableModels
        case .openAICompatible:
            return servedModels.map {
                InferenceModelOption(tag: $0, displayName: $0, provider: backend.providerLabel)
            }
        }
    }

    // MARK: - Module overrides

    private var moduleOverrideRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "switch.2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.headerInactiveIcon)
                    .frame(width: PeekSettingsRowMetrics.iconWidth)
                Text(peek: "Feature overrides")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.tertiaryLabel)
            }
            ForEach(overrideModules, id: \.self) { module in
                PeekSettingsToggleRow(
                    icon: icon(for: module),
                    title: title(for: module),
                    detail: profile.moduleOverrides.value(for: module) == nil
                        ? "Following the global setting"
                        : "Overridden for this profile",
                    isOn: overrideBinding(for: module)
                )
            }
            if !profile.moduleOverrides.isEmpty {
                PeekSettingsCommandRow(
                    icon: "arrow.uturn.backward",
                    title: "Use global defaults",
                    subtitle: "Clear this profile's feature overrides",
                    trailing: .button("Reset"),
                    action: { store.clearModuleOverrides(id: profileID) }
                )
            }
        }
    }

    private var overrideModules: [ModuleID] {
        [.webLookup, .voiceInput, .speakAnswers, .saveConversation, .suggestFollowUps]
    }

    /// Shows the EFFECTIVE value; toggling writes a profile override for it.
    private func overrideBinding(for module: ModuleID) -> Binding<Bool> {
        Binding(
            get: { Module.isEnabled(module, in: orchestrator.settings, profile: profile) },
            set: { store.setModuleOverride(id: profileID, module: module, enabled: $0) }
        )
    }

    private func icon(for module: ModuleID) -> String {
        switch module {
        case .webLookup: "globe.americas"
        case .voiceInput: "mic"
        case .speakAnswers: "speaker.wave.2"
        case .saveConversation: "archivebox"
        case .suggestFollowUps: "sparkles"
        default: "questionmark"
        }
    }

    private func title(for module: ModuleID) -> String {
        switch module {
        case .webLookup: "Web lookup"
        case .voiceInput: "Voice input"
        case .speakAnswers: "Read answers aloud"
        case .saveConversation: "Save conversations"
        case .suggestFollowUps: "Suggest follow-ups"
        default: module.rawValue
        }
    }
}

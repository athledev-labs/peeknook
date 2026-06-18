// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// The Tool section of ``PeekProfileEditor``, shown only for a `.tool`-primary profile (which has no
/// grounds pills — its grounds are just `[.tool]`). Edits the profile's ``ToolSpec`` one field at a
/// time through `ProfileStore.setToolSpec`, which forces the HTTP transport. The signed app exposes the
/// HTTP transport only; the `command` transport is dev-only and never reachable here. Every URL goes
/// through ``PeekSettingsController/toolURLValidity(_:)`` for the inline note and
/// ``PeekSettingsController/toolReachable(_:)`` for the user-triggered Test connection probe, both of
/// which apply the same HTTPS gate as inference.
struct PeekProfileToolSection: View {
    var settings: PeekSettingsController
    var store: ProfileStore
    var profileID: String

    @Environment(\.nookResolvedTheme) private var theme
    @State private var urlDraft = ""
    @State private var labelDraft = ""
    @State private var didLoad = false
    @State private var probe: ProbeState = .idle

    /// The probe lifecycle the Test connection row renders. The network states mirror ``ToolHealth``;
    /// `.idle`/`.checking` are local to the button.
    private enum ProbeState: Equatable {
        case idle, checking, reachable, unreachable, rejected, unconfigured
    }

    /// The current spec, defaulting to a fresh HTTP spec so a profile whose tool was stripped on import
    /// still edits cleanly.
    private var spec: ToolSpec {
        store.profile(id: profileID).toolSpec ?? ToolSpec(transport: .http, url: "", sendsScreenshot: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            PeekSettingsNote(
                text: "This profile runs a local tool over each capture and answers from its result. Start the tool, then point this at its address."
            )

            urlField
            urlValidityNote
            testConnectionRow

            PeekSettingsToggleRow(
                icon: "camera.viewfinder",
                title: "Send screenshot",
                detail: "Send the captured screenshot to the tool as input.",
                isOn: screenshotBinding
            )
            PeekSettingsToggleRow(
                icon: "text.alignleft",
                title: "Send selected text",
                detail: "Send the captured or selected text to the tool as input.",
                isOn: textBinding
            )

            outputLabelField
            timeoutRow
        }
        .task(id: profileID) {
            urlDraft = spec.url ?? ""
            labelDraft = spec.outputLabel
            didLoad = true
            probe = .idle
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)
            Text(peek: "Tool")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.tertiaryLabel)
        }
    }

    // MARK: - URL

    private var urlField: some View {
        PeekSettingsFormField(
            icon: "link",
            title: "Tool URL",
            text: urlBinding,
            placeholder: "http://127.0.0.1:7000",
            monospaced: true
        )
    }

    private var urlBinding: Binding<String> {
        Binding(
            get: { urlDraft },
            set: { newValue in
                urlDraft = newValue
                guard didLoad else { return }
                write { $0.url = newValue }
                probe = .idle   // editing the address invalidates any prior reachability result
            }
        )
    }

    @ViewBuilder
    private var urlValidityNote: some View {
        switch settings.toolURLValidity(urlDraft) {
        case .insecureRemote:
            PeekSettingsNote(text: "A remote tool must use HTTPS.")
        case .invalid:
            PeekSettingsNote(text: "That is not a valid tool address.")
        case .empty, .valid:
            EmptyView()
        }
    }

    // MARK: - Test connection

    private var testConnectionRow: some View {
        PeekSettingsCommandRow(
            icon: "dot.radiowaves.left.and.right",
            title: "Test connection",
            subtitle: probeSubtitle,
            trailing: .button(probe == .checking ? "Checking…" : "Test"),
            action: runProbe
        )
    }

    private var probeSubtitle: String {
        switch probe {
        case .idle:        return "Check that the tool is running and reachable"
        case .checking:    return "Checking the tool address…"
        case .reachable:   return "The tool answered. It is reachable."
        case .unreachable: return "No answer. Start the tool, then try again."
        case .rejected:    return "Fix the tool address first."
        case .unconfigured: return "Add a tool address first."
        }
    }

    private func runProbe() {
        guard probe != .checking else { return }
        probe = .checking
        let current = spec
        Task { @MainActor in
            let health = await settings.toolReachable(current)
            switch health {
            case .reachable:    probe = .reachable
            case .unreachable:  probe = .unreachable
            case .rejected:     probe = .rejected
            case .unconfigured: probe = .unconfigured
            }
        }
    }

    // MARK: - Toggles

    private var screenshotBinding: Binding<Bool> {
        Binding(get: { spec.sendsScreenshot }, set: { value in write { $0.sendsScreenshot = value } })
    }

    private var textBinding: Binding<Bool> {
        Binding(get: { spec.sendsText }, set: { value in write { $0.sendsText = value } })
    }

    // MARK: - Output label

    private var outputLabelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            PeekSettingsFormField(
                icon: "tag",
                title: "Result heading",
                text: labelBinding,
                placeholder: ToolSpec.defaultOutputLabel
            )
            PeekSettingsNote(text: "Shown to the model as the heading above the tool's result.")
        }
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { labelDraft },
            set: { newValue in
                labelDraft = String(newValue.prefix(ToolSpec.maxOutputLabelLength))
                guard didLoad else { return }
                write { $0.outputLabel = labelDraft }
            }
        )
    }

    // MARK: - Timeout

    private var timeoutRow: some View {
        HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: "timer")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                Text(peek: "Timeout")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: "How long the tool may run before the answer continues without it.")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            stepperButton(symbol: "minus", label: "Decrease timeout", delta: -1)
                .disabled(spec.timeoutSeconds <= ToolSpec.minTimeoutSeconds)
            Text(verbatim: "\(Int(spec.timeoutSeconds))s")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.primaryLabel.opacity(0.95))
                .frame(minWidth: 30)
            stepperButton(symbol: "plus", label: "Increase timeout", delta: 1)
                .disabled(spec.timeoutSeconds >= ToolSpec.maxTimeoutSeconds)
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    private func stepperButton(symbol: String, label: String, delta: Double) -> some View {
        Button {
            let next = min(max(spec.timeoutSeconds + delta, ToolSpec.minTimeoutSeconds), ToolSpec.maxTimeoutSeconds)
            write { $0.timeoutSeconds = next }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(theme.primaryLabel.opacity(0.9))
                .frame(width: 22, height: 22)
                .background(theme.subtleFill.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .peekAction(label: label)
    }

    // MARK: - One-field write

    /// Reads the current spec, mutates one field, and saves through the store (which forces HTTP and
    /// drops any command). Keeps every edit a single persisted mutation, matching the other editors.
    private func write(_ mutate: (inout ToolSpecDraft) -> Void) {
        var draft = ToolSpecDraft(spec)
        mutate(&draft)
        store.setToolSpec(id: profileID, draft.spec)
    }
}

/// A mutable view of the editable ``ToolSpec`` fields, so the editor can change one at a time without
/// re-listing the full initializer at every call site. Always rebuilds an HTTP spec; the store applies
/// the same force-HTTP sanitize as a second net.
private struct ToolSpecDraft {
    var url: String?
    var sendsScreenshot: Bool
    var sendsText: Bool
    var outputLabel: String
    var timeoutSeconds: Double

    init(_ spec: ToolSpec) {
        url = spec.url
        sendsScreenshot = spec.sendsScreenshot
        sendsText = spec.sendsText
        outputLabel = spec.outputLabel
        timeoutSeconds = spec.timeoutSeconds
    }

    var spec: ToolSpec {
        ToolSpec(
            transport: .http,
            url: url,
            sendsScreenshot: sendsScreenshot,
            sendsText: sendsText,
            outputLabel: outputLabel,
            timeoutSeconds: timeoutSeconds
        )
    }
}

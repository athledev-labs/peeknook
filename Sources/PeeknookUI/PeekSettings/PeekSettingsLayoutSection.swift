// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Settings → Layout: reorder or hide the commands in the notch bars. Order/visibility only — it never
/// touches capture or inference. Writes through ``PeekSettingsController`` (which sanitizes protected
/// ids and persists sparse deltas under the global scope); reads the resolved layout back through the
/// orchestrator's single resolution choke point, so this view never reaches into settings directly.
///
/// Only the bars with customizable commands are offered (`Home`/idle and `Answer`/result). The Confirm
/// and Camera bars are all-protected (every command is pinned or an exit), so there is nothing to edit.
/// Structural commands (Capture, Done, Cancel, Use this, Shutter) render with disabled controls — they
/// are listed for context but can never be hidden or moved (``CommandDescriptor/isCustomizable``).
struct PeekSettingsLayoutSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController

    @Environment(\.nookResolvedTheme) private var theme
    @State private var selected: CommandPlacement = .idle
    @State private var confirmingReset = false

    /// The bars worth editing — the two with customizable commands.
    private static let placements: [CommandPlacement] = [.idle, .result]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsNote(
                text: "Reorder or hide the commands in the notch bars. Capture, Done, and Cancel stay put. Your layout applies everywhere."
            )

            placementPicker

            ForEach(rows) { command in
                HStack(spacing: PeekSettingsRowMetrics.rowSpacing) {
                    toggleRegion(command)
                    reorderButtons(command)
                }
                .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
            }

            if hasAnyOverrides {
                PeekSettingsCommandRow(
                    icon: "arrow.uturn.backward",
                    title: "Reset to default",
                    subtitle: "Restore the shipped order and visibility for every bar",
                    style: .destructive,
                    trailing: .button("Reset"),
                    action: { confirmingReset = true }
                )
            }
        }
        .confirmationDialog(
            Text(peek: "Reset command layout?"),
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                settings.resetCommandLayout()
            } label: {
                Text(peek: "Reset")
            }
            Button(role: .cancel) { } label: { Text(peek: "Cancel") }
        } message: {
            Text(peek: "Every bar returns to its shipped order and visibility.")
        }
    }

    // MARK: Placement picker

    private var placementPicker: some View {
        HStack(spacing: 6) {
            ForEach(Self.placements, id: \.self) { placement in
                PeekSurfaceFilterPill(
                    title: placementLabel(placement),
                    isSelected: selected == placement,
                    hint: "Edit this bar",
                    action: { selected = placement }
                )
            }
        }
    }

    // MARK: Rows

    /// One command's icon + title + show/hide toggle, exposed to VoiceOver as a single switch (the
    /// reorder buttons are a separate sibling region so they stay independently focusable).
    private func toggleRegion(_ command: CommandDescriptor) -> some View {
        let visible = !hiddenIDs.contains(command.id)
        return HStack(spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: command.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(visible ? theme.accent : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)
                .peekDecorative()

            Text(peek: command.titleKey)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.primaryLabel.opacity(visible ? 0.95 : 0.55))
                .lineLimit(1)

            if !command.isCustomizable {
                Text(peek: "Always shown")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            Spacer(minLength: 8)

            PeekSettingsTogglePill(isOn: Binding(
                get: { !hiddenIDs.contains(command.id) },
                set: { settings.setCommandHidden(command.id, in: selected, hidden: !$0) }
            ))
            .disabled(!command.isCustomizable)
            .opacity(command.isCustomizable ? 1 : 0.4)
        }
        .contentShape(Rectangle())
        .peekToggle(
            label: command.titleKey,
            isOn: visible,
            hint: command.isCustomizable ? "Show or hide this command" : "Always shown — required",
            toggle: {
                guard command.isCustomizable else { return }
                settings.setCommandHidden(command.id, in: selected, hidden: visible)
            }
        )
    }

    private func reorderButtons(_ command: CommandDescriptor) -> some View {
        HStack(spacing: 2) {
            moveButton(command, symbol: "chevron.up", delta: -1, enabled: canMoveUp(command), label: "Move up")
            moveButton(command, symbol: "chevron.down", delta: 1, enabled: canMoveDown(command), label: "Move down")
        }
    }

    private func moveButton(
        _ command: CommandDescriptor, symbol: String, delta: Int, enabled: Bool, label: String
    ) -> some View {
        Button {
            settings.moveCommand(command.id, in: selected, by: delta)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? theme.tertiaryLabel : theme.quaternaryLabel)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .peekAction(label: label, hint: command.titleKey)
    }

    // MARK: Derived state

    private var overrides: [CommandOverride] {
        orchestrator.resolvedCommandOverrides(for: selected)
    }

    /// All commands in the selected bar, in the user's current order, keeping hidden ones (so they can
    /// be un-hidden) and the protected ones (rendered with disabled controls).
    private var rows: [CommandDescriptor] {
        CommandLayout.screenDefault.orderedForEditing(selected, applying: overrides)
    }

    private var hiddenIDs: Set<String> {
        Set(overrides.filter(\.hidden).map(\.id))
    }

    private var movableIDs: [String] {
        rows.filter(\.isCustomizable).map(\.id)
    }

    private var hasAnyOverrides: Bool {
        !orchestrator.settings.commandOverrides(forScope: PeeknookSettings.globalCommandScope).isEmpty
    }

    private func canMoveUp(_ command: CommandDescriptor) -> Bool {
        guard command.isCustomizable, let index = movableIDs.firstIndex(of: command.id) else { return false }
        return index > 0
    }

    private func canMoveDown(_ command: CommandDescriptor) -> Bool {
        guard command.isCustomizable, let index = movableIDs.firstIndex(of: command.id) else { return false }
        return index < movableIDs.count - 1
    }

    private func placementLabel(_ placement: CommandPlacement) -> String {
        switch placement {
        case .idle:       return "Home"
        case .result:     return "Answer"
        case .active:      return "Confirm"
        case .cameraLive:  return "Camera"
        }
    }
}

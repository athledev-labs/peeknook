// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Renders one command bar from ``CommandLayout`` descriptors.
///
/// It owns only the bar's *layout and generic rendering*: it filters the placement's descriptors to
/// those visible in the supplied ``CommandBarContext``, splits them into a leading horizontal scroll
/// and trailing pinned commands (so Capture / Done stay reachable on a narrow panel), and renders
/// each plain `.button` as a `NookToolbarButton` with its resolved title/symbol/help/prominence,
/// hotkey, accessibility identifier, and disabled state.
///
/// Everything orchestrator-specific stays in the host: action dispatch is the `dispatch` closure, and
/// genuinely bespoke cells (the preflight `.valueDropdown` pills bound to settings, the Resume preview
/// button) are supplied through `special`. The bar never reaches into `PeeknookHost` and carries no
/// state of its own — keeping it a pure function of `(layout, context)` plus host callbacks.
struct PeekCommandBar: View {
    let placement: CommandPlacement
    var layout: CommandLayout = .screenDefault
    let context: CommandBarContext
    var spacing: CGFloat = 8
    /// Maps a descriptor's hotkey slot to the live ``CaptureHotkey`` (an unbacked slot returns nil).
    var resolveHotkey: (HotkeySlot) -> CaptureHotkey? = { _ in nil }
    /// Per-command help that the static `helpKey` can't express (Brief surfaces the current brief).
    var dynamicHelp: (CommandAction?) -> String? = { _ in nil }
    /// Dispatches a `.button` command's action to the orchestrator / host.
    let dispatch: (CommandAction) -> Void
    /// Bespoke rendering for dropdowns and the Resume preview; nil → render the default button.
    var special: (CommandDescriptor) -> AnyView? = { _ in nil }

    var body: some View {
        let visible = layout.visibleCommands(placement, in: context)
        let scrolling = visible.filter { !$0.pinnedTrailing }
        let pinned = visible.filter(\.pinnedTrailing)
        HStack(alignment: .center, spacing: spacing) {
            PeekScrollView(.horizontal) {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(scrolling) { cell($0) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(pinned) { command in
                cell(command).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ command: CommandDescriptor) -> some View {
        if let custom = special(command) {
            custom
        } else {
            NookToolbarButton(
                title: command.resolvedTitleKey(in: context),
                symbol: command.resolvedSymbol(in: context),
                hotkey: hotkey(for: command),
                help: dynamicHelp(command.action) ?? command.resolvedHelpKey(in: context),
                testIdentifier: command.accessibilityIdentifier,
                prominent: command.isProminent(in: context),
                action: { if let action = command.action { dispatch(action) } }
            )
            .disabled(command.isDisabled(in: context))
        }
    }

    private func hotkey(for command: CommandDescriptor) -> CaptureHotkey? {
        guard case let .settingsSlot(slot) = command.hotkey else { return nil }
        return resolveHotkey(slot)
    }
}

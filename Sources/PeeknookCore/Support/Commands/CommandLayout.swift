// SPDX-License-Identifier: Apache-2.0

import Foundation

/// An ordered set of commands across every placement. Code-defined in Phase 1.5.
public struct CommandLayout: Codable, Sendable, Equatable {
    public let commands: [CommandDescriptor]

    public init(commands: [CommandDescriptor]) {
        self.commands = commands
    }

    /// The commands for one bar, in render order, with the user's layout ``CommandOverride`` deltas
    /// applied. Empty overrides return the exact filter+sort the bar shipped with — the byte-identical
    /// migration anchor (``CommandLayout/screenDefault``).
    ///
    /// TWO-BUCKET merge, deliberately NOT a single shared integer axis: commands the user reordered (a
    /// customizable command carrying a non-nil ``CommandOverride/order``) emit first in that order;
    /// every other command — including any command added in a future release with no override entry —
    /// appends afterward in ``CommandDescriptor/defaultOrder``. So a newly shipped command keeps its
    /// authored slot among the un-reordered commands and can never collide with a saved user rank,
    /// vanish, or land non-deterministically. (A reorder writes dense ranks for the placement's
    /// customizable commands — see `PeekSettingsController.moveCommand` — which is collision-free here
    /// precisely because new commands fall to bucket 2.)
    ///
    /// Non-customizable commands ignore overrides entirely (never hidden, never reordered), so neither
    /// the editor nor a hand-edited settings blob can strip a bar's Capture trigger or a surface's exit.
    public func forPlacement(_ placement: CommandPlacement, applying overrides: [CommandOverride]) -> [CommandDescriptor] {
        merged(placement, applying: overrides, includeHidden: false)
    }

    /// The commands for one bar, in render order. The no-override anchor (delegates with no overrides),
    /// kept byte-identical to the shipped bars so ``CommandLayoutTests`` stays the structural floor.
    public func forPlacement(_ placement: CommandPlacement) -> [CommandDescriptor] {
        forPlacement(placement, applying: [])
    }

    /// Editor-facing ordering: the placement in the user's current order but KEEPING hidden commands
    /// (so Settings → Layout can show a hidden command's toggle to bring it back) and KEEPING
    /// non-customizable commands (rendered with disabled controls). Same two-bucket order as the bar.
    public func orderedForEditing(_ placement: CommandPlacement, applying overrides: [CommandOverride]) -> [CommandDescriptor] {
        merged(placement, applying: overrides, includeHidden: true)
    }

    private func merged(
        _ placement: CommandPlacement,
        applying overrides: [CommandOverride],
        includeHidden: Bool
    ) -> [CommandDescriptor] {
        let base = commands
            .filter { $0.placement == placement }
            .sorted { $0.defaultOrder < $1.defaultOrder }
        guard !overrides.isEmpty else { return base }

        let byID = Dictionary(overrides.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Hide drops only customizable commands; a non-customizable command ignores any hidden flag.
        let survivors = includeHidden
            ? base
            : base.filter { !($0.isCustomizable && byID[$0.id]?.hidden == true) }

        // Bucket 1: user-reordered (customizable + explicit order), by that order. Bucket 2: everything
        // else, by defaultOrder. A future command with no entry is always in bucket 2 — never collides.
        var reordered: [CommandDescriptor] = []
        var rest: [CommandDescriptor] = []
        for command in survivors {
            if command.isCustomizable, byID[command.id]?.order != nil {
                reordered.append(command)
            } else {
                rest.append(command)
            }
        }
        reordered.sort { lhs, rhs in
            let lo = byID[lhs.id]?.order ?? lhs.defaultOrder
            let ro = byID[rhs.id]?.order ?? rhs.defaultOrder
            return lo != ro ? lo < ro : lhs.defaultOrder < rhs.defaultOrder
        }
        return reordered + rest
    }
}

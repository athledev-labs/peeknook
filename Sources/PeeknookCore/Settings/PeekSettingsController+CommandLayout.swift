// SPDX-License-Identifier: Apache-2.0

import Foundation

// Command bar layout (Settings → Layout): show/hide, reorder, reset, and their sparse-override
// helpers. The override-bucket helpers stay private — they are used only by these editors.
@MainActor
extension PeekSettingsController {
    /// Show or hide a command in its bar. A no-op for a non-customizable (protected) command and for a
    /// state that already matches — defense in depth alongside the apply-seam guard. Sparse: a
    /// hidden-only command keeps a `nil`-order entry; un-hiding back to the default drops it.
    public func setCommandHidden(_ id: String, in placement: CommandPlacement, hidden: Bool) {
        guard Self.isCustomizableCommand(id) else { return }
        var bucket = currentGlobalCommandOverrides
        if let index = bucket.firstIndex(where: { $0.id == id }) {
            guard bucket[index].hidden != hidden else { return }
            bucket[index] = CommandOverride(id: id, order: bucket[index].order, hidden: hidden)
        } else {
            guard hidden else { return }  // un-hiding a command with no entry is already the default
            bucket.append(CommandOverride(id: id, hidden: true))
        }
        writeGlobalCommandOverrides(bucket)
    }

    /// Move a command one slot within its bar (delta -1 up / +1 down) among the customizable commands
    /// only. Writes DENSE ranks for that bar's customizable commands — collision-free under the
    /// two-bucket apply seam, since a future command with no entry falls to bucket 2 and appends after.
    /// A no-op at the ends or for an unknown / protected id; other bars' deltas are left untouched.
    public func moveCommand(_ id: String, in placement: CommandPlacement, by delta: Int) {
        guard Self.isCustomizableCommand(id) else { return }
        let current = currentGlobalCommandOverrides
        var movable = CommandLayout.screenDefault
            .orderedForEditing(placement, applying: current)
            .filter(\.isCustomizable)
        guard let index = movable.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard movable.indices.contains(target) else { return }  // first-up / last-down no-op
        movable.swapAt(index, target)

        let hiddenIDs = Set(current.filter(\.hidden).map(\.id))
        let placementIDs = Set(CommandLayout.screenDefault.forPlacement(placement).map(\.id))
        var bucket = current.filter { !placementIDs.contains($0.id) }  // keep other placements' deltas
        for (rank, command) in movable.enumerated() {
            bucket.append(CommandOverride(id: command.id, order: rank, hidden: hiddenIDs.contains(command.id)))
        }
        writeGlobalCommandOverrides(bucket)
    }

    /// Restore every bar to its shipped order and visibility. Early-returns when nothing is customized.
    public func resetCommandLayout() {
        guard !currentGlobalCommandOverrides.isEmpty else { return }
        update { $0.commandOverrides[PeeknookSettings.globalCommandScope] = nil }
    }

    private var currentGlobalCommandOverrides: [CommandOverride] {
        settings.commandOverrides(forScope: PeeknookSettings.globalCommandScope)
    }

    private func writeGlobalCommandOverrides(_ bucket: [CommandOverride]) {
        let cleaned = Self.sanitizedCommandOverrides(bucket)
        guard cleaned != currentGlobalCommandOverrides else { return }
        update { $0.commandOverrides[PeeknookSettings.globalCommandScope] = cleaned.isEmpty ? nil : cleaned }
    }

    /// Drop entries that are unknown, protected, or empty (no order and not hidden) before persist — a
    /// stale or hostile blob can never store a protected-command override or accumulate inert rows.
    private static func sanitizedCommandOverrides(_ bucket: [CommandOverride]) -> [CommandOverride] {
        let byID = Dictionary(
            CommandLayout.cameraStudy.commands.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return bucket.filter { entry in
            guard let descriptor = byID[entry.id], descriptor.isCustomizable else { return false }
            return entry.order != nil || entry.hidden
        }
    }

    private static func isCustomizableCommand(_ id: String) -> Bool {
        CommandLayout.cameraStudy.commands.first(where: { $0.id == id })?.isCustomizable ?? false
    }
}

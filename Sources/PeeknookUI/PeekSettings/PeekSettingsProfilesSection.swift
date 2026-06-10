// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI

/// Settings → Profiles: pick the active profile, duplicate the Screen built-in into an editable
/// copy, and delete copies. Built-in names localize via `Text(peek:)`; user-typed names render
/// verbatim (never through the catalog). The camera built-in is deliberately absent — camera
/// capture stays ⌘⇧C/event-scoped, and a camera-primary ACTIVE profile would dead-end ⌘⇧P.
struct PeekSettingsProfilesSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController

    @Environment(\.nookResolvedTheme) private var theme
    @State private var pendingDelete: GroundProfile?

    private var store: ProfileStore? { orchestrator.profileStore }

    /// Activatable profiles: the Screen built-in + the user's copies (no camera.study).
    private var entries: [GroundProfile] {
        [.screenDefault] + (store?.catalog.profiles ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsNote(
                text: "A profile bundles a standing instruction, an answer model, and feature overrides. The active profile shapes every capture."
            )

            ForEach(entries) { profile in
                profileRow(profile)
            }

            if store != nil {
                PeekSettingsCommandRow(
                    icon: "plus.square.on.square",
                    title: "New profile",
                    subtitle: "Duplicate Screen into an editable copy",
                    trailing: .button("Duplicate"),
                    action: duplicateScreen
                )
            }
        }
        .confirmationDialog(
            Text(peek: "Delete this profile?"),
            isPresented: deleteDialogPresented,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                if let profile = pendingDelete {
                    settings.deleteProfile(id: profile.id)
                }
                pendingDelete = nil
            } label: {
                Text(peek: "Delete")
            }
            Button(role: .cancel) {
                pendingDelete = nil
            } label: {
                Text(peek: "Cancel")
            }
        } message: {
            Text(peek: "Its instruction, model binding, and overrides are removed. Chats are not affected.")
        }
    }

    private var deleteDialogPresented: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func profileRow(_ profile: GroundProfile) -> some View {
        let isActive = orchestrator.settings.activeProfileID == profile.id
        return HStack(alignment: .center, spacing: PeekSettingsRowMetrics.rowSpacing) {
            Image(systemName: profile.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isActive ? theme.accent : theme.headerInactiveIcon)
                .frame(width: PeekSettingsRowMetrics.iconWidth)

            VStack(alignment: .leading, spacing: 2) {
                profileName(profile)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.primaryLabel.opacity(0.95))
                Text(peek: profile.isBuiltIn ? "Built-in" : "Your profile")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(theme.tertiaryLabel)
            }

            Spacer(minLength: 8)

            if isActive {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .peekDecorative()
                    Text(peek: "Active")
                        .font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(theme.accent)
            } else {
                PeekSurfaceFilterPill(
                    title: "Use",
                    isSelected: false,
                    hint: "Activate this profile",
                    action: { settings.setActiveProfile(id: profile.id) }
                )
            }

            if !profile.isBuiltIn {
                Button {
                    pendingDelete = profile
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .peekAction(label: "Delete profile", hint: "Removes this profile")
            }
        }
        .padding(.vertical, PeekSettingsRowMetrics.rowVerticalPadding)
    }

    /// THE verbatim-vs-catalog branch: built-ins localize their key; user names are user data.
    @ViewBuilder
    private func profileName(_ profile: GroundProfile) -> some View {
        if profile.isBuiltIn {
            Text(peek: profile.displayNameKey)
        } else {
            Text(verbatim: profile.displayName ?? PeekLocalized(.init(profile.displayNameKey)))
        }
    }

    private func duplicateScreen() {
        guard let store else { return }
        let seedName = PeekLocalized("Copy of \(PeekLocalized(.init(GroundProfile.screenDefault.displayNameKey)))")
        _ = store.duplicate(.screenDefault, name: seedName)
    }
}

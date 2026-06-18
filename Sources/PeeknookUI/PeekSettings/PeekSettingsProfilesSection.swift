// SPDX-License-Identifier: Apache-2.0

import PeeknookDesign
import PeeknookCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Profiles: pick the active profile, duplicate the Screen built-in into an editable
/// copy, delete copies, and share/install profiles as portable presets. Built-in names localize via
/// `Text(peek:)`; user-typed names render verbatim (never through the catalog). The camera built-in is
/// deliberately absent — camera capture stays ⌘⇧C/event-scoped, and a camera-primary ACTIVE profile
/// would dead-end ⌘⇧P.
struct PeekSettingsProfilesSection: View {
    var orchestrator: SessionOrchestrator
    var settings: PeekSettingsController

    @Environment(\.nookResolvedTheme) private var theme
    @State private var pendingDelete: GroundProfile?
    @State private var expandedProfileID: String?
    @State private var exportDocument: ProfilePresetDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var importNotice: String?

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
                if !profile.isBuiltIn, expandedProfileID == profile.id, let store {
                    PeekProfileEditor(
                        orchestrator: orchestrator,
                        settings: settings,
                        store: store,
                        profileID: profile.id
                    )
                    .padding(.leading, PeekSettingsRowMetrics.iconWidth + 8)
                }
            }

            if let store {
                PeekSettingsCommandRow(
                    icon: "plus.square.on.square",
                    title: "New profile",
                    subtitle: "Duplicate Screen into an editable copy",
                    trailing: .button("Duplicate"),
                    action: duplicateScreen
                )

                PeekSettingsCommandRow(
                    icon: "wrench.and.screwdriver",
                    title: "New tool profile",
                    subtitle: "Create a profile that runs a local tool",
                    trailing: .button("Create"),
                    action: createToolProfile
                )

                PeekSettingsCommandRow(
                    icon: "square.and.arrow.down",
                    title: "Import profiles",
                    subtitle: "Install profiles from a shared preset file",
                    trailing: .button("Import"),
                    action: { importNotice = nil; isImporting = true }
                )

                if !store.catalog.profiles.isEmpty {
                    PeekSettingsCommandRow(
                        icon: "square.and.arrow.up",
                        title: "Export profiles",
                        subtitle: "Save your profiles as a shareable preset file",
                        trailing: .button("Export"),
                        action: beginExport
                    )
                }

                if let importNotice {
                    // Already localized in `handleImport` (the count case interpolates), so render
                    // verbatim rather than re-routing through the catalog as a key.
                    Text(verbatim: importNotice)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(theme.tertiaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Peeknook Profiles"
        ) { _ in
            exportDocument = nil
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
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
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        expandedProfileID = expandedProfileID == profile.id ? nil : profile.id
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.tertiaryLabel)
                        .rotationEffect(.degrees(expandedProfileID == profile.id ? 90 : 0))
                }
                .buttonStyle(.plain)
                .peekAction(label: "Edit profile", hint: "Name, instruction, model, and overrides")

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

    /// Mints a `.tool`-primary profile and expands its editor so the user can point it at a local tool.
    /// Like New profile it does not auto-activate.
    private func createToolProfile() {
        guard let store, let created = store.createToolProfile(name: PeekLocalized("Tool profile")) else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            expandedProfileID = created.id
        }
    }

    // MARK: - Import / export

    /// Export the user's whole catalog (built-ins never ship — `exportPreset` drops them).
    private func beginExport() {
        guard let store, let data = try? store.exportPreset() else { return }
        exportDocument = ProfilePresetDocument(data: data)
        isExporting = true
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        guard let store, case let .success(urls) = result, let url = urls.first else { return }
        // The file lives outside the app sandbox; take the security scope for the read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importNotice = PeekLocalized("That file could not be read.")
            return
        }
        // importPreset is tolerant: hostile or malformed bytes add nothing.
        let added = store.importPreset(from: data)
        switch added.count {
        case 0:
            importNotice = PeekLocalized("No profiles found in that file.")
            return
        case 1:
            importNotice = PeekLocalized("Added 1 profile.")
        default:
            importNotice = PeekLocalized("Added \(added.count) profiles.")
        }
        // A tool profile expects a local tool to be running (a shared preset never carries an executable,
        // and a loopback tool the user must start themselves), so hint that after a successful import.
        if added.contains(where: { $0.primaryGround == .tool || $0.toolSpec != nil }) {
            importNotice = (importNotice ?? "") + " "
                + PeekLocalized("An imported profile runs a local tool. Start the tool, then confirm its address in the profile editor.")
        }
    }
}

/// A `FileDocument` wrapper so SwiftUI's `fileExporter` can write preset bytes produced by
/// ``ProfileStore/exportPreset(ids:)``. Read is unused (import goes through `fileImporter` +
/// ``ProfileStore/importPreset(from:)``), so it returns the bytes verbatim.
struct ProfilePresetDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

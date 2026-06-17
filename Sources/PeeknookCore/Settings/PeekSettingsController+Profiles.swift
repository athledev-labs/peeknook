// SPDX-License-Identifier: Apache-2.0

import Foundation

// Profile activation and deletion (the permission matrix and warm model follow the profile).
@MainActor
extension PeekSettingsController {
    /// Activate a profile by id (built-in or user copy). Refreshes readiness (the permission
    /// matrix follows the profile) and prewarms the profile's bound model.
    public func setActiveProfile(id: String) {
        guard settings.activeProfileID != id else { return }
        update { $0.activeProfileID = id }
        Task {
            await setup.refresh()
            orchestrator.prewarm()
        }
    }

    /// Delete a user profile; when it was the active one, fall back to `screen.default`
    /// explicitly (the resolver would anyway — this keeps the persisted id honest).
    public func deleteProfile(id: String) {
        guard let store = orchestrator.profileStore else { return }
        if store.delete(id: id, activeProfileID: settings.activeProfileID) {
            update { $0.activeProfileID = GroundProfile.screenDefault.id }
            Task {
                await setup.refresh()
                orchestrator.prewarm()
            }
        }
    }
}

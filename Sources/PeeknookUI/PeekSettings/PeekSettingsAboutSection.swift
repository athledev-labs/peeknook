// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsAboutSection: View {
    var profile: SystemProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsValueRow(label: "Version", value: PeekAppMetadata.versionLabel)
            PeekSettingsValueRow(label: "Memory", value: "\(profile.physicalMemoryGB) GB")
        }
    }
}

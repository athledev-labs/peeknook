// SPDX-License-Identifier: Apache-2.0

import PeeknookCore
import SwiftUI

struct PeekSettingsAboutSection: View {
    var profile: SystemProfile

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PeekSettingsValueRow(label: "Version", value: PeekAppMetadata.versionLabel)
            PeekSettingsValueRow(label: "Memory", value: "\(profile.physicalMemoryGB) GB")
            linkRow(title: "Privacy policy", url: PeekAppMetadata.privacyPolicyURL)
            linkRow(title: "Licenses", url: PeekAppMetadata.licensesURL)
            linkRow(title: "Report an issue", url: PeekAppMetadata.issuesURL)
        }
    }

    private func linkRow(title: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
            }
        }
        .buttonStyle(.plain)
        .peekAction(label: title, hint: "Opens in your browser")
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

enum PeekAppMetadata {
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        if build == "—" || build == version {
            return version
        }
        return "\(version) (\(build))"
    }
}

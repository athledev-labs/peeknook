// SPDX-License-Identifier: Apache-2.0

import Foundation

enum PeekAppMetadata {
    static let repositoryURL = URL(string: "https://github.com/glendonC/peeknook")!
    static let privacyPolicyURL = URL(string: "https://github.com/glendonC/peeknook/blob/main/PRIVACY.md")!
    static let licensesURL = URL(string: "https://github.com/glendonC/peeknook/blob/main/NOTICE")!
    static let releasesURL = URL(string: "https://github.com/glendonC/peeknook/releases/latest")!
    /// The no-Terminal install guide, linked from the setup Ollama row's "Need help?" affordance.
    static let setupHelpURL = URL(string: "https://github.com/glendonC/peeknook/blob/main/INSTALL.md")!
    static var issuesURL: URL {
        URL(string: "https://github.com/glendonC/peeknook/issues/new/choose")!
    }

    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "-"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        if build == "-" || build == version {
            return version
        }
        return "\(version) (\(build))"
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

enum PeekAppMetadata {
    static let repositoryURL = URL(string: "https://github.com/glendonC/peeknook")!
    /// Public summary until a dedicated policy URL ships with the website.
    static var privacyPolicyURL: URL {
        repositoryURL.appendingPathComponent("blob/main/README.md")
    }
    static var licensesURL: URL {
        repositoryURL.appendingPathComponent("blob/main/README.md")
    }
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

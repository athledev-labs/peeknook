// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Launch-argument gates for the UI test host. Production builds ignore these unless the args
/// are present on the process command line.
enum PeeknookTestMode {
    static let launchArgument = "-PeeknookTestMode"
    static let openSettingsArgument = "-PeeknookTestOpenSettings"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    static var opensSettingsOnLaunch: Bool {
        ProcessInfo.processInfo.arguments.contains(openSettingsArgument)
    }
}

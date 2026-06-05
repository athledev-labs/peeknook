// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookCore

/// Builds the multi-module OpenNook host for Peeknook and sibling nook apps.
public enum PeeknookHostConfiguration {
    @MainActor
    public static func make() -> NookHostConfiguration {
        var host = NookHostConfiguration()
        host.branding = NookHostBranding(
            hostName: "Peeknook",
            hostTagline: "Local practice copilot in the notch."
        )

        host.register(PeeknookModule.moduleDescriptor) { context in
            PeeknookModule(context: context)
        }

        HostModuleRegistry.registerAdditionalModules(into: &host)

        host.defaultModule = PeeknookModuleID.peeknook

        // Optional: cycle other modules with Control-Option-` (like MultiNook).
        // host.moduleCycleHotkey = NookHotkey(keyCode: 50, carbonModifiers: 4096 | 2048, keySymbol: "`")

        return host
    }
}

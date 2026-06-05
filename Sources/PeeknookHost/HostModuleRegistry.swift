// SPDX-License-Identifier: Apache-2.0

import NookApp

/// Extension point for additional nook modules in the same host process.
///
/// Register your other projects here so they share one menu-bar host and the module
/// switcher (see OpenNook `MultiNook`):
///
/// ```swift
/// host.register(
///     NookModuleDescriptor(id: "com.you.clock", displayName: "Clock", icon: "clock")
/// ) { context in ClockModule(context: context) }
/// ```
public enum HostModuleRegistry {
    @MainActor
    public static func registerAdditionalModules(into host: inout NookHostConfiguration) {
        // Intentionally empty — add sibling nook apps below.
        _ = host
    }
}

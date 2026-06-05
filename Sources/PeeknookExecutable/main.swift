// SPDX-License-Identifier: Apache-2.0

import NookApp
import PeeknookHost

// Multi-module host: Peeknook is the default module; register siblings in HostModuleRegistry.
NookApp.main(PeeknookHostConfiguration.make())

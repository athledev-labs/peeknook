// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A capability filter for the model library. Today only `installed`; `vision` / `cloud` / `fitsRAM`
/// / `backend` are reserved for later slices (they need, respectively, a live `/api/show` probe, a
/// model byte-size predicate, and a typed `InferenceBackend` on the option).
public enum ModelLibraryCapabilityFilter: String, Sendable, CaseIterable, Hashable {
    case installed
}

/// Pure, UI-independent filtering for the model library so the rule is unit-testable without the
/// SwiftUI surface (the test target imports only `PeeknookCore`).
public enum ModelLibraryFilters {
    /// Options matching ALL active filters. An empty filter set returns every option unchanged.
    /// `.installed` keeps options whose tag is tag-aware-matched against `installedNames`
    /// (`gemma4:e2b` ≠ `gemma4:e4b`; a bare name resolves to `:latest`).
    public static func apply(
        _ filters: Set<ModelLibraryCapabilityFilter>,
        to options: [InferenceModelOption],
        installedNames: [String]
    ) -> [InferenceModelOption] {
        guard !filters.isEmpty else { return options }
        return options.filter { option in
            filters.allSatisfy { filter in
                switch filter {
                case .installed:
                    return ModelTag.matches(installedNames: installedNames, wanted: option.tag)
                }
            }
        }
    }
}

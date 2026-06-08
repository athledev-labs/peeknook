// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One model page from a remote catalog (Ollama library today).
public struct RemoteCatalogModel: Identifiable, Equatable, Sendable {
    public var id: String { modelID }
    public let modelID: String
    public let displayName: String
    public let pageURL: URL?

    public init(modelID: String, displayName: String, pageURL: URL? = nil) {
        self.modelID = modelID
        self.displayName = displayName
        self.pageURL = pageURL
    }
}

/// One installable tag from a remote catalog entry.
public struct RemoteCatalogTag: Equatable, Sendable {
    /// Install/pull identifier (Ollama tag today).
    public let id: String
    public let pullHint: String?

    public init(id: String, pullHint: String? = nil) {
        self.id = id
        self.pullHint = pullHint
    }
}

public enum CatalogTagTrait: String, Sendable, CaseIterable {
    case likelyVision
    case cloud
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Internal backend for remote model browse metadata.
protocol RemoteModelCataloging: Sendable {
    func search(query: String, page: Int) async throws -> [RemoteCatalogModel]
    func tags(for modelID: String) async throws -> [RemoteCatalogTag]
    func traits(modelID: String, tag: String) -> Set<CatalogTagTrait>
    func likelySupportsVision(modelID: String, tags: [String]) -> Bool
    func isCloudTag(_ tag: String) -> Bool
}

/// Ollama-backed remote catalog; swap for other backends in ``PeeknookServices.makeStack``.
struct OllamaRemoteModelCatalog: RemoteModelCataloging, Sendable {
    var client = OllamaCatalogClient()

    func search(query: String, page: Int) async throws -> [RemoteCatalogModel] {
        try await client.search(query: query, page: page).map { model in
            RemoteCatalogModel(
                modelID: model.modelID,
                displayName: model.displayName,
                pageURL: model.pageURL
            )
        }
    }

    func tags(for modelID: String) async throws -> [RemoteCatalogTag] {
        try await client.tags(for: modelID).map { detail in
            RemoteCatalogTag(id: detail.tag, pullHint: detail.pullCommand)
        }
    }

    func traits(modelID: String, tag: String) -> Set<CatalogTagTrait> {
        var traits = Set<CatalogTagTrait>()
        if OllamaCatalogClient.isCloudTag(tag) { traits.insert(.cloud) }
        if OllamaCatalogClient.likelySupportsVision(modelID: modelID, tags: [tag]) {
            traits.insert(.likelyVision)
        }
        return traits
    }

    func likelySupportsVision(modelID: String, tags: [String]) -> Bool {
        OllamaCatalogClient.likelySupportsVision(modelID: modelID, tags: tags)
    }

    func isCloudTag(_ tag: String) -> Bool {
        OllamaCatalogClient.isCloudTag(tag)
    }
}

/// Backend-swappable facade for model tag identity, curated lists, and remote catalog browse.
/// Keeps Ollama-specific clients out of PeeknookUI.
public struct ModelCatalogService: Sendable {
    private let remote: any RemoteModelCataloging

    public var providerLabel: String { "Ollama" }

    init(remote: any RemoteModelCataloging) {
        self.remote = remote
    }

    public static func makeDefault() -> ModelCatalogService {
        ModelCatalogService(remote: OllamaRemoteModelCatalog())
    }

    // MARK: - Tag identity

    public func normalizedTag(_ raw: String) -> String {
        ModelTag.normalized(raw)
    }

    public func matchesModel(installedNames: [String], wanted: String) -> Bool {
        ModelTag.matches(installedNames: installedNames, wanted: wanted)
    }

    public func isSameModel(_ lhs: String, _ rhs: String) -> Bool {
        ModelTag.isSame(lhs, rhs)
    }

    // MARK: - Curated library

    public func curatedModels(recommendedTag: String) -> [InferenceModelOption] {
        let offered = TextModelCatalog.offered
        return offered.sorted { lhs, rhs in
            let lhsRec = matchesModel(installedNames: [lhs.tag], wanted: recommendedTag)
            let rhsRec = matchesModel(installedNames: [rhs.tag], wanted: recommendedTag)
            if lhsRec != rhsRec { return lhsRec }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public func isRecommended(tag: String, recommendedTag: String) -> Bool {
        matchesModel(installedNames: [tag], wanted: recommendedTag)
    }

    public func inferenceOption(catalogModel: RemoteCatalogModel, tag: RemoteCatalogTag) -> InferenceModelOption {
        InferenceModelOption(
            tag: tag.id,
            displayName: catalogModel.displayName,
            provider: providerLabel
        )
    }

    // MARK: - Remote catalog

    public func searchCatalog(query: String, page: Int = 1) async throws -> [RemoteCatalogModel] {
        try await remote.search(query: query, page: page)
    }

    public func catalogTags(for modelID: String) async throws -> [RemoteCatalogTag] {
        try await remote.tags(for: modelID)
    }

    // MARK: - Browse heuristics

    public func traits(modelID: String, tag: String) -> Set<CatalogTagTrait> {
        remote.traits(modelID: modelID, tag: tag)
    }

    public func likelySupportsVision(modelID: String, tags: [String] = []) -> Bool {
        remote.likelySupportsVision(modelID: modelID, tags: tags)
    }

    public func isCloudTag(_ tag: String) -> Bool {
        remote.isCloudTag(tag)
    }
}

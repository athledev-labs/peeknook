// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

@MainActor
final class StorageFootprintServiceTests: XCTestCase {
    func testSnapshotWhenPersistenceDisabledShowsDisabledArchive() async {
        let service = StorageFootprintService(
            archive: ConversationArchiveTestSupport.makeStore(directory: makeTempDir()),
            systemProfile: { SystemProfile(physicalMemoryGB: 16, suggestedTextModel: "gemma4:e2b") }
        )

        let snapshot = await service.snapshot(
            persistConversation: false,
            ollamaBaseURL: "http://127.0.0.1:11434",
            acceptInsecureRemoteOllama: false
        )

        XCTAssertEqual(snapshot.archive, .disabled)
        XCTAssertEqual(snapshot.systemMemoryGB, 16)
        XCTAssertEqual(snapshot.suggestedTextModel, "gemma4:e2b")
    }

    func testSnapshotWithEmptyArchiveShowsEmptyState() async {
        let service = StorageFootprintService(
            archive: ConversationArchiveTestSupport.makeStore(directory: makeTempDir()),
            ollama: stubOllamaClient(),
            systemProfile: { SystemProfile(physicalMemoryGB: 24, suggestedTextModel: "gemma4:e4b") }
        )

        let snapshot = await service.snapshot(
            persistConversation: true,
            ollamaBaseURL: "http://127.0.0.1:11434",
            acceptInsecureRemoteOllama: false
        )

        XCTAssertEqual(snapshot.archive, .empty)
        if case .local(let disk) = snapshot.ollamaDisk {
            XCTAssertEqual(disk.modelCount, 2)
            XCTAssertEqual(disk.totalBytes, 5_000_000_000)
        } else {
            XCTFail("Expected local Ollama disk footprint")
        }
        XCTAssertEqual(snapshot.ollamaMemory, .noneLoaded)
    }

    func testSnapshotWithSavedThreadsReportsOnDiskBytes() async throws {
        let dir = makeTempDir()
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let thread = ConversationThread(turns: [ChatTurn(id: 1, kind: .user("hello"))])
        _ = await store.save(thread)

        let service = StorageFootprintService(
            archive: store,
            ollama: stubOllamaClient(running: [OllamaLoadedModelFootprint(name: "gemma4:e4b", sizeBytes: 4_500_000_000)]),
            systemProfile: { SystemProfile(physicalMemoryGB: 32, suggestedTextModel: "gemma4:26b") }
        )

        let snapshot = await service.snapshot(
            persistConversation: true,
            ollamaBaseURL: "http://127.0.0.1:11434",
            acceptInsecureRemoteOllama: false
        )

        guard case .inUse(let footprint) = snapshot.archive else {
            return XCTFail("Expected in-use archive")
        }
        XCTAssertEqual(footprint.threadCount, 1)
        XCTAssertGreaterThan(footprint.usedBytes, 0)
        if case .loaded(let models) = snapshot.ollamaMemory {
            XCTAssertEqual(models.first?.name, "gemma4:e4b")
            XCTAssertEqual(models.first?.sizeBytes, 4_500_000_000)
        } else {
            XCTFail("Expected loaded model memory footprint")
        }
    }

    func testRemoteOllamaSkipsDiskAndMemoryProbes() async {
        let service = StorageFootprintService(
            archive: ConversationArchiveTestSupport.makeStore(directory: makeTempDir()),
            ollama: stubOllamaClient()
        )

        let snapshot = await service.snapshot(
            persistConversation: true,
            ollamaBaseURL: "https://ollama.example.com",
            acceptInsecureRemoteOllama: true
        )

        if case .unavailable(let reason) = snapshot.ollamaDisk {
            XCTAssertTrue(reason.contains("local Ollama"))
        } else {
            XCTFail("Expected unavailable disk state for remote Ollama")
        }
        if case .unavailable(let reason) = snapshot.ollamaMemory {
            XCTAssertTrue(reason.contains("local Ollama"))
        } else {
            XCTFail("Expected unavailable memory state for remote Ollama")
        }
    }

    func testOllamaUnreachableSurfacesUnavailableReason() async {
        let service = StorageFootprintService(
            archive: ConversationArchiveTestSupport.makeStore(directory: makeTempDir()),
            ollama: OllamaSetupClient(session: failingSession())
        )

        let snapshot = await service.snapshot(
            persistConversation: true,
            ollamaBaseURL: "http://127.0.0.1:11434",
            acceptInsecureRemoteOllama: false
        )

        if case .unavailable = snapshot.ollamaDisk {
            // expected
        } else {
            XCTFail("Expected unavailable disk when Ollama is down")
        }
    }

    func testByteFormatUsesFileUnits() {
        XCTAssertFalse(ByteFormat.storage(0).isEmpty)
        XCTAssertTrue(ByteFormat.storage(2_621_440).contains("MB") || ByteFormat.storage(2_621_440).contains("KB"))
        XCTAssertTrue(ByteFormat.storage(5_000_000_000).contains("GB"))
    }

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PeeknookFootprint-\(UUID().uuidString)", isDirectory: true)
    }

    private func stubOllamaClient(
        running: [OllamaLoadedModelFootprint] = []
    ) -> OllamaSetupClient {
        OllamaSetupClient(session: makeOllamaStubSession(running: running))
    }

    private func makeOllamaStubSession(running: [OllamaLoadedModelFootprint]) -> URLSession {
        let tagsJSON = """
        {"models":[{"name":"gemma4:e4b","size":3000000000},{"name":"gemma4:e2b","size":2000000000}]}
        """
        let psModels = running.map { #"{"name":"\#($0.name)","size":\#($0.sizeBytes)}"# }.joined(separator: ",")
        let psJSON = "{\"models\":[\(psModels)]}"

        OllamaURLProtocolStub.responsesByPath = [
            "/api/tags": [.init(statusCode: 200, body: Data(tagsJSON.utf8), headers: [:])],
            "/api/ps": [.init(statusCode: 200, body: Data(psJSON.utf8), headers: [:])],
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return URLSession(configuration: config)
    }

    private func failingSession() -> URLSession {
        OllamaURLProtocolStub.responsesByPath = [:]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OllamaURLProtocolStub.self]
        return URLSession(configuration: config)
    }
}

final class OllamaFootprintParsingTests: XCTestCase {
    func testTagsResponseDecodesOptionalSize() throws {
        let json = #"{"models":[{"name":"gemma4:e4b","size":4567890123}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: json)
        XCTAssertEqual(decoded.models.count, 1)
        XCTAssertEqual(decoded.models[0].name, "gemma4:e4b")
        XCTAssertEqual(decoded.models[0].size, 4_567_890_123)
    }

    func testTagsResponseToleratesMissingSize() throws {
        let json = #"{"models":[{"name":"gemma4:e4b"}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: json)
        XCTAssertNil(decoded.models[0].size)
    }

    func testPsResponseDecodesRunningModels() throws {
        let json = #"{"models":[{"name":"gemma4:e4b","size":3900000000}]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(OllamaPsResponse.self, from: json)
        XCTAssertEqual(decoded.models[0].name, "gemma4:e4b")
        XCTAssertEqual(decoded.models[0].size, 3_900_000_000)
    }
}

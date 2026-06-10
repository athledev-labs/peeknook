// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class CaptureBlobStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("peeknook-blobs-\(UUID().uuidString)", isDirectory: true)
    }

    private let sampleBase64 = StubCaptureProvider.defaultScreenshotBase64

    func testStoreLoadDeleteRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CaptureBlobStore(directory: dir)

        let id = try store.store(jpegBase64: sampleBase64)
        XCTAssertEqual(try store.loadBase64(id: id), sampleBase64)

        try store.delete(ids: [id])
        XCTAssertNil(try store.loadBase64(id: id))
    }

    func testEncryptedBlobRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let protection = FixedKeyArchiveProtection()
        let store = CaptureBlobStore(directory: dir, protection: protection)

        let id = try store.store(jpegBase64: sampleBase64)
        let raw = try Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).jpg"))
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(raw))
        XCTAssertEqual(try store.loadBase64(id: id), sampleBase64)
    }

    func testLegacyPlaintextBlobStillLoads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let jpeg = Data(base64Encoded: sampleBase64)!
        try jpeg.write(to: dir.appendingPathComponent("\(id.uuidString).jpg"))

        let store = CaptureBlobStore(directory: dir, protection: FixedKeyArchiveProtection())
        XCTAssertEqual(try store.loadBase64(id: id), sampleBase64)
    }

    func testCaptureResultEncodesBlobReferenceWithoutInlineBase64() throws {
        let capture = CaptureResult(
            text: nil,
            sourceLabel: "Window",
            screenshotBlobID: UUID()
        )
        let data = try JSONEncoder().encode(capture)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("screenshotBlobID"))
        XCTAssertFalse(json.contains("screenshotBase64"))
    }

    func testLegacyCaptureResultDecodesInlineBase64() throws {
        let capture = CaptureResult(text: nil, sourceLabel: "Window", screenshotBase64: sampleBase64)
        let data = try JSONEncoder().encode(capture)
        let decoded = try JSONDecoder().decode(CaptureResult.self, from: data)
        XCTAssertEqual(decoded.screenshotBase64, sampleBase64)
        XCTAssertNil(decoded.screenshotBlobID)
    }

    func testArchiveSaveExternalizesInlineScreenshots() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let protection = FixedKeyArchiveProtection(key: ConversationArchiveTestSupport.sharedTestKey)
        let store = ConversationArchiveTestSupport.makeStore(directory: dir, protection: protection)

        let capture = CaptureResult(text: nil, sourceLabel: "Safari", screenshotBase64: sampleBase64)
        let thread = ConversationThread(turns: [
            ChatTurn(id: 1, kind: .image(capture)),
            ChatTurn(id: 2, kind: .assistant("answer")),
        ])
        let save = await store.save(thread)
        XCTAssertTrue(save.isSuccess)

        let blobsDir = dir.appendingPathComponent("blobs", isDirectory: true)
        let blobFiles = try FileManager.default.contentsOfDirectory(at: blobsDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(blobFiles.count, 1)

        let blobStore = CaptureBlobStore(
            directory: dir.appendingPathComponent("blobs", isDirectory: true),
            protection: protection
        )
        let loaded = await store.load(id: thread.id)
        guard case .image(let restored) = loaded?.turns.first?.kind else {
            return XCTFail("expected image turn")
        }
        XCTAssertNil(restored.screenshotBase64)
        XCTAssertNotNil(restored.screenshotBlobID)
        XCTAssertEqual(try blobStore.loadBase64(id: restored.screenshotBlobID!), sampleBase64)
        XCTAssertTrue(ArchiveEnvelope.isEncrypted(try Data(contentsOf: blobStore.blobURL(restored.screenshotBlobID!))))

        let summaries = await store.summaries()
        XCTAssertEqual(summaries.first?.thumbnailBlobID, restored.screenshotBlobID)
        let indexRaw = try Data(contentsOf: dir.appendingPathComponent("index.v2.json"))
        XCTAssertFalse(String(data: indexRaw, encoding: .utf8)?.contains("screenshotBase64") ?? false)
    }

    func testArchiveLoadMigratesLegacyInlineThread() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)

        let capture = CaptureResult(text: nil, sourceLabel: "Legacy", screenshotBase64: sampleBase64)
        let thread = ConversationThread(turns: [ChatTurn(id: 1, kind: .image(capture))])
        let plaintext = try JSONEncoder().encode(thread)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plaintext.write(to: dir.appendingPathComponent("\(thread.id.uuidString).json"))

        let loaded = await store.load(id: thread.id)
        guard case .image(let restored) = loaded?.turns.first?.kind else {
            return XCTFail("expected image turn")
        }
        XCTAssertNil(restored.screenshotBase64)
        XCTAssertNotNil(restored.screenshotBlobID)
    }

    func testThreadDeleteRemovesReferencedBlobs() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let protection = FixedKeyArchiveProtection(key: ConversationArchiveTestSupport.sharedTestKey)
        let store = ConversationArchiveTestSupport.makeStore(directory: dir, protection: protection)

        let capture = CaptureResult(text: nil, sourceLabel: "Window", screenshotBase64: sampleBase64)
        let thread = ConversationThread(turns: [ChatTurn(id: 1, kind: .image(capture))])
        let save = await store.save(thread)
        XCTAssertTrue(save.isSuccess)

        let loaded = await store.load(id: thread.id)
        guard case .image(let restored) = loaded?.turns.first?.kind,
              let blobID = restored.screenshotBlobID else {
            return XCTFail("expected blob reference")
        }

        let blobStore = CaptureBlobStore(
            directory: dir.appendingPathComponent("blobs", isDirectory: true),
            protection: protection
        )
        await store.delete(id: thread.id)
        XCTAssertNil(try blobStore.loadBase64(id: blobID))
    }

    @MainActor
    func testOrchestratorOffloadsScreenshotWhenPersistenceEnabled() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let protection = FixedKeyArchiveProtection()
        let blobStore = CaptureBlobStore(
            directory: dir.appendingPathComponent("blobs", isDirectory: true),
            protection: protection
        )

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, persistConversation: true),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen", screenshotBase64: sampleBase64)]),
            inference: MockInferenceEngine(tokens: ["done"])
        )
        orchestrator.captureBlobStore = blobStore

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("done")

        guard case .image(let stored) = orchestrator.conversation.first?.kind else {
            return XCTFail("expected image turn")
        }
        XCTAssertNil(stored.screenshotBase64)
        XCTAssertNotNil(stored.screenshotBlobID)
    }

    @MainActor
    func testOrchestratorKeepsInlineScreenshotWhenPersistenceDisabled() async {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blobStore = CaptureBlobStore(directory: dir.appendingPathComponent("blobs", isDirectory: true))

        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(previewBeforeInfer: false, persistConversation: false),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "screen", screenshotBase64: sampleBase64)]),
            inference: MockInferenceEngine(tokens: ["done"])
        )
        orchestrator.captureBlobStore = blobStore

        orchestrator.beginCapture()
        _ = await orchestrator.waitForResult("done")

        guard case .image(let stored) = orchestrator.conversation.first?.kind else {
            return XCTFail("expected image turn")
        }
        XCTAssertEqual(stored.screenshotBase64, sampleBase64)
        XCTAssertNil(stored.screenshotBlobID)
        XCTAssertTrue(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path))?.isEmpty ?? true
        )
    }
}

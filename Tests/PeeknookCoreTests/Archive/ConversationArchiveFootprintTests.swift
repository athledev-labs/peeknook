// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import PeeknookCore

@MainActor
final class ConversationArchiveFootprintTests: XCTestCase {
    func testFootprintIncludesThreadIndexAndBlobs() async throws {
        let dir = makeTempDir()
        let store = ConversationArchiveTestSupport.makeStore(directory: dir)
        let thread = ConversationThread(turns: [
            ChatTurn(
                id: 1,
                kind: .image(CaptureResult(
                    text: nil,
                    sourceLabel: "Vision",
                    appName: "Safari",
                    windowTitle: "Test",
                    screenshotBase64: minimalJPEGBase64()
                ))
            ),
        ])
        _ = await store.save(thread)

        let footprint = await store.footprint()
        XCTAssertEqual(footprint.threadCount, 1)
        XCTAssertGreaterThan(footprint.usedBytes, 0)
        XCTAssertEqual(footprint.maxBytes, ConversationArchiveStore.defaultMaxBytes)
        XCTAssertEqual(footprint.maxThreads, ConversationArchiveStore.defaultMaxThreads)
    }

    func testFootprintEmptyArchiveReportsZeroBytes() async {
        let store = ConversationArchiveTestSupport.makeStore(directory: makeTempDir())
        let footprint = await store.footprint()
        XCTAssertEqual(footprint.threadCount, 0)
        XCTAssertEqual(footprint.usedBytes, 0)
    }

    func testBlobStoreBytesOnDiskMatchesWrittenFiles() throws {
        let dir = makeTempDir().appendingPathComponent("blobs", isDirectory: true)
        let store = CaptureBlobStore(directory: dir)
        _ = try store.store(jpegBase64: minimalJPEGBase64())
        XCTAssertGreaterThan(store.bytesOnDisk(), 0)
    }

    private func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PeeknookArchiveFootprint-\(UUID().uuidString)", isDirectory: true)
    }

    private func minimalJPEGBase64() -> String {
        Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
    }
}

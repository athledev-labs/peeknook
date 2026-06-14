// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class ByteFormatHintTests: XCTestCase {
    func testParsesCuratedHints() {
        XCTAssertEqual(ByteFormat.bytes(fromGigabytesHint: "~7 GB"), 7_000_000_000)
        XCTAssertEqual(ByteFormat.bytes(fromGigabytesHint: "~10 GB"), 10_000_000_000)
        XCTAssertEqual(ByteFormat.bytes(fromGigabytesHint: "~18 GB"), 18_000_000_000)
        XCTAssertEqual(ByteFormat.bytes(fromGigabytesHint: "~20 GB"), 20_000_000_000)
        XCTAssertEqual(ByteFormat.bytes(fromGigabytesHint: "10 GB"), 10_000_000_000, "No leading '~' must still parse.")
    }

    func testReturnsNilForUnparseable() {
        XCTAssertNil(ByteFormat.bytes(fromGigabytesHint: nil))
        XCTAssertNil(ByteFormat.bytes(fromGigabytesHint: "a large download"))
        XCTAssertNil(ByteFormat.bytes(fromGigabytesHint: ""))
    }

    func testEstimatedDownloadBytesDerivesFromHint() {
        let e4b = TextModelCatalog.offered.first { $0.tag == "gemma4:e4b" }
        XCTAssertEqual(e4b?.estimatedDownloadBytes, 10_000_000_000)

        // A custom tag has no hint → unknown size → the disk pre-check skips.
        let custom = InferenceModelOption(custom: CustomModelEntry(tag: "myorg/mymodel"))
        XCTAssertNil(custom.estimatedDownloadBytes)
    }
}

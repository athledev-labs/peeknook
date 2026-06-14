// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

final class TextModelCatalogTests: XCTestCase {
    private func option(_ tag: String) -> InferenceModelOption {
        TextModelCatalog.offered.first { $0.tag == tag }!
    }

    func testLeanerAlternativeWalksDownTheCuratedTiers() {
        XCTAssertEqual(TextModelCatalog.leanerAlternative(to: option("gemma4:e4b"))?.tag, "gemma4:e2b")
        XCTAssertEqual(TextModelCatalog.leanerAlternative(to: option("gemma4:26b"))?.tag, "gemma4:e4b")
        XCTAssertEqual(TextModelCatalog.leanerAlternative(to: option("gemma4:31b"))?.tag, "gemma4:26b")
    }

    func testSmallestTierAndCustomTagsHaveNoLeanerAlternative() {
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: option("gemma4:e2b")), "The smallest tier has nothing leaner.")
        let custom = InferenceModelOption(custom: CustomModelEntry(tag: "myorg/mymodel"))
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: custom), "A custom tag has no defined ordering.")
    }

    func testOfferedTiersAreOrderedSmallestToLargest() {
        // leanerAlternative relies on `offered` being smallest→largest (index-1 = next-leaner). Guard it.
        let bytes = TextModelCatalog.offered.map { $0.estimatedDownloadBytes ?? 0 }
        XCTAssertEqual(bytes, bytes.sorted(), "Curated tiers must stay ordered smallest→largest by size.")
    }
}

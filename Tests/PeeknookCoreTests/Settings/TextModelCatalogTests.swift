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
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: option("gemma4:e2b")), "The smallest Gemma tier has nothing leaner in its family.")
        let custom = InferenceModelOption(custom: CustomModelEntry(tag: "myorg/mymodel"))
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: custom), "A custom tag has no defined ordering.")
    }

    func testLeanerAlternativeStaysWithinFamily() {
        // Qwen2.5-VL 7B is a SMALLER download than Gemma 4 E2B, but it must NOT be offered as e2b's
        // "faster, lighter" alternative: across families the smaller model is the more capable one,
        // so the download-confirmation copy would be backwards. leanerAlternative is family-scoped.
        let qwen = option("qwen2.5vl:7b")
        let e2b = option("gemma4:e2b")
        XCTAssertLessThan(qwen.estimatedDownloadBytes ?? .max, e2b.estimatedDownloadBytes ?? 0,
                          "Precondition: Qwen is a smaller download than e2b.")
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: e2b),
                     "A cross-family smaller model must never be offered as the leaner alternative.")
        XCTAssertNil(TextModelCatalog.leanerAlternative(to: qwen),
                     "Qwen is the only curated model in its family, so it has no leaner alternative.")
    }

    func testQwenVLIsCuratedAsAVisionModelWithASummary() {
        let qwen = option("qwen2.5vl:7b")
        XCTAssertTrue(qwen.supportsVision, "Qwen2.5-VL is a vision model.")
        XCTAssertEqual(qwen.downloadHint, "~6 GB")
        XCTAssertEqual(qwen.capabilitySummary, "Sharp at reading detailed screens (charts, tables, documents); fits most Macs.")
    }

    func testOfferedTiersAreOrderedSmallestToLargest() {
        // leanerAlternative relies on `offered` being smallest→largest (index-1 = next-leaner). Guard it.
        let bytes = TextModelCatalog.offered.map { $0.estimatedDownloadBytes ?? 0 }
        XCTAssertEqual(bytes, bytes.sorted(), "Curated tiers must stay ordered smallest→largest by size.")
    }

    func testEveryCuratedTierCarriesAPlainLanguageCapabilitySummary() {
        // The picker sells models by what they can do, not by file size — so each curated tier must
        // carry a summary (and it must not leak an em dash into user-facing copy).
        for option in TextModelCatalog.offered {
            let summary = option.capabilitySummary ?? ""
            XCTAssertFalse(summary.isEmpty, "\(option.tag) is missing a capability summary.")
            XCTAssertFalse(summary.contains("—"), "\(option.tag) summary must not contain an em dash.")
        }
        // The smallest tier warns about misreading detailed images; that caveat is the whole point.
        XCTAssertTrue(option("gemma4:e2b").capabilitySummary?.contains("may misread") == true)
    }

    func testCustomTagsCarryNoCapabilitySummary() {
        // We can't stand behind a claim for a model the user brought, so it gets no summary and the
        // picker falls back to the tag.
        let custom = InferenceModelOption(custom: CustomModelEntry(tag: "myorg/mymodel"))
        XCTAssertNil(custom.capabilitySummary)
    }

    // MARK: - RAM-floor-driven recommendation (the catalog owns the RAM→model policy)

    func testRecommendedTagPicksTheHeaviestAffordableModel() {
        // The whole RAM→model ladder is read off recommendedRAMFloorGB, so this is the single source
        // of truth SystemProfile delegates to. Floors today: e2b 0, qwen 16, e4b 32, 26b 48, 31b nil.
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 4), "gemma4:e2b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 15), "gemma4:e2b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 16), "qwen2.5vl:7b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 18), "qwen2.5vl:7b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 31), "qwen2.5vl:7b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 32), "gemma4:e4b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 47), "gemma4:e4b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 48), "gemma4:26b")
        XCTAssertEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: 128), "gemma4:26b")
    }

    func testRecommendedTagAndSystemProfileAgree() {
        // SystemProfile.recommendedModel must be a pure delegate — no second copy of the policy.
        for gb in [1, 8, 15, 16, 24, 31, 32, 47, 48, 64, 256] {
            XCTAssertEqual(
                SystemProfile.recommendedModel(forPhysicalMemoryGB: gb),
                TextModelCatalog.recommendedTag(forPhysicalMemoryGB: gb),
                "\(gb) GB: SystemProfile must delegate to the catalog"
            )
        }
    }

    func testManualOnlyModelsAreNeverAutoRecommended() {
        // 31b has a nil floor (power-user pick), so no amount of RAM auto-suggests it; 26b stays the cap.
        for gb in [48, 64, 128, 512, 100_000] {
            XCTAssertNotEqual(TextModelCatalog.recommendedTag(forPhysicalMemoryGB: gb), "gemma4:31b")
        }
        // Whatever it returns is always a real curated tag with a non-nil floor.
        for gb in [1, 16, 32, 48, 1024] {
            let tag = TextModelCatalog.recommendedTag(forPhysicalMemoryGB: gb)
            let picked = TextModelCatalog.offered.first { $0.tag == tag }
            XCTAssertNotNil(picked, "\(gb) GB: recommended a tag not in the catalog")
            XCTAssertNotNil(picked?.recommendedRAMFloorGB, "\(gb) GB: recommended a manual-only model")
        }
    }

    func testCustomTagsHaveNoRAMFloorSoTheyAreNeverAutoRecommended() {
        let custom = InferenceModelOption(custom: CustomModelEntry(tag: "myorg/mymodel"))
        XCTAssertNil(custom.recommendedRAMFloorGB)
    }
}

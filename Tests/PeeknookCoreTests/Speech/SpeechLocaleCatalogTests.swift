// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The pure labeling/sorting that turns a device's raw speech-supported locales into the caption
/// source-language picker rows. Clock-free and device-free (it takes the locales as input), so it pins
/// the "no typos, no duplicates, stable English labels, sorted" behavior apart from the Speech probe.
final class SpeechLocaleCatalogTests: XCTestCase {

    func testLabelsLocalesWithEnglishRegionQualifiedNames() {
        let langs = SpeechLocaleCatalog.languages(from: [Locale(identifier: "ko-KR")])
        XCTAssertEqual(langs.count, 1)
        XCTAssertEqual(langs.first?.identifier, "ko-KR")
        XCTAssertEqual(langs.first?.displayName, "Korean (South Korea)")
    }

    func testSortsAlphabeticallyByDisplayName() {
        let langs = SpeechLocaleCatalog.languages(from: [
            Locale(identifier: "ko-KR"),   // Korean …
            Locale(identifier: "ar-SA"),   // Arabic …
            Locale(identifier: "ja-JP"),   // Japanese …
        ])
        XCTAssertEqual(langs.map(\.displayName), [
            "Arabic (Saudi Arabia)", "Japanese (Japan)", "Korean (South Korea)",
        ])
    }

    func testDeduplicatesByDisplayName() {
        // Two identifiers that resolve to the same English label collapse to one row.
        let langs = SpeechLocaleCatalog.languages(from: [
            Locale(identifier: "en-US"),
            Locale(identifier: "en_US"),
        ])
        XCTAssertEqual(langs.count, 1, "an identical display name must not appear twice in the picker")
    }

    func testDropsLocalesWithNoResolvableName() {
        let langs = SpeechLocaleCatalog.languages(from: [Locale(identifier: "zz-ZZ")])
        XCTAssertTrue(langs.allSatisfy { !$0.displayName.isEmpty })
    }
}

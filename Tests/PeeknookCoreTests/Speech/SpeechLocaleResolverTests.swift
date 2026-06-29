// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Pure BCP-47 resolution of the free-text source-language label over a FIXED supported set (so the test
/// never depends on the host's installed dictation packs). The hardware on-device probe is separate.
final class SpeechLocaleResolverTests: XCTestCase {
    private let supported = [
        Locale(identifier: "en-US"),
        Locale(identifier: "ja-JP"),
        Locale(identifier: "pt-BR"),
        Locale(identifier: "pt-PT"),
    ]

    func testExactIdentifierMatch() {
        XCTAssertEqual(SpeechLocaleResolver.locale(forLanguageLabel: "pt-BR", supported: supported)?.identifier, "pt-BR")
        XCTAssertEqual(SpeechLocaleResolver.locale(forLanguageLabel: "ja-JP", supported: supported)?.identifier, "ja-JP")
    }

    func testUnderscoreIdentifierNormalizes() {
        XCTAssertEqual(SpeechLocaleResolver.locale(forLanguageLabel: "en_US", supported: supported)?.identifier, "en-US")
    }

    func testBareLanguageCodeMatch() {
        XCTAssertEqual(
            SpeechLocaleResolver.locale(forLanguageLabel: "ja", supported: supported)?.identifier, "ja-JP",
            "an unqualified 'ja' resolves to the supported ja locale"
        )
    }

    func testEnglishDisplayNameMatch() {
        XCTAssertEqual(
            SpeechLocaleResolver.locale(forLanguageLabel: "Japanese", supported: supported)?.language.languageCode?.identifier, "ja",
            "the English display name resolves to the ja locale"
        )
    }

    func testUnmappableReturnsNil() {
        XCTAssertNil(SpeechLocaleResolver.locale(forLanguageLabel: "Klingon", supported: supported), "an unsupported language fails closed")
        XCTAssertNil(SpeechLocaleResolver.locale(forLanguageLabel: "   ", supported: supported), "blank fails closed")
        XCTAssertNil(SpeechLocaleResolver.locale(forLanguageLabel: nil, supported: supported), "nil (auto) fails closed for an explicit lookup")
    }
}

// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// Guards that every localization KEY carried by ``CommandLayout/screenDefault`` actually exists in
/// `Localizable.xcstrings`.
///
/// SwiftUI resolves a `LocalizedStringKey` that is absent from the catalog to the key text itself —
/// it never fails or blanks — so a missing key is **invisible** to a normal build and to
/// `swift test`. Because descriptors freeze their keys into data, this test is the only thing that
/// turns that silent degradation into a hard failure. It parses the SOURCE catalog from the repo
/// (the bundled form is compiled), located relative to this test file.
final class CommandLayoutCatalogTests: XCTestCase {
    func testEveryScreenDefaultLocalizationKeyExistsInTheCatalog() throws {
        let catalogKeys = try loadCatalogKeys()

        var referenced = Set<String>()
        for command in CommandLayout.screenDefault.commands {
            referenced.insert(command.titleKey)
            command.helpKey.map { referenced.insert($0) }
            if let face = command.alternateFace {
                face.titleKey.map { referenced.insert($0) }
                face.helpKey.map { referenced.insert($0) }
            }
            // command.symbol and alternateFace.symbol are SF Symbol names, NOT catalog keys — skip.
        }

        let missing = referenced.subtracting(catalogKeys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "screenDefault references \(missing.count) localization key(s) missing from "
                + "Localizable.xcstrings (add them): \(missing)"
        )
    }

    func testEveryCameraStudyLocalizationKeyExistsInTheCatalog() throws {
        let catalogKeys = try loadCatalogKeys()

        var referenced = Set<String>()
        for command in CommandLayout.cameraStudy.commands {
            referenced.insert(command.titleKey)
            command.helpKey.map { referenced.insert($0) }
            if let face = command.alternateFace {
                face.titleKey.map { referenced.insert($0) }
                face.helpKey.map { referenced.insert($0) }
            }
        }

        let missing = referenced.subtracting(catalogKeys).sorted()
        XCTAssertTrue(
            missing.isEmpty,
            "cameraStudy references \(missing.count) localization key(s) missing from "
                + "Localizable.xcstrings (add them): \(missing)"
        )
    }

    // MARK: - Loading the source catalog

    private func loadCatalogKeys() throws -> Set<String> {
        let url = try Self.catalogURL()
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let strings = json?["strings"] as? [String: Any] else {
            throw XCTSkip("Could not parse strings table at \(url.path)")
        }
        return Set(strings.keys)
    }

    /// `Sources/PeeknookUI/Resources/Localizable.xcstrings`, resolved from this test's `#filePath`
    /// (`<repo>/Tests/PeeknookCoreTests/Support/<thisFile>` → four levels up to the repo root).
    private static func catalogURL() throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // PeeknookCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = repoRoot
            .appendingPathComponent("Sources/PeeknookUI/Resources/Localizable.xcstrings")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Localizable.xcstrings not found at \(url.path)")
        }
        return url
    }
}

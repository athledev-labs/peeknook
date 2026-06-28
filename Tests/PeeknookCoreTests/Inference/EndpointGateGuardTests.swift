// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// A source-level lint that backstops the structural M2 invariant: inference code must obtain a URL
/// only through ``EndpointURLPolicy`` (via ``InferenceEndpoint/resolvedBaseURL()`` for a built endpoint,
/// or the policy directly for the string-`baseURL` probe methods) — never by constructing one itself.
/// It runs in the normal `swift test` pass, so a future engine that bypasses the HTTPS / loopback gate
/// fails fast in the dev loop, not only in CI. Scans the whole inference tree, so a NEW engine is
/// covered automatically.
final class EndpointGateGuardTests: XCTestCase {
    /// The package root, found by walking up from this test file until `Package.swift` appears — robust
    /// to where the worktree lives and to CI checkout paths.
    private var packageRoot: URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while !fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }   // reached the filesystem root; give up rather than loop
            dir = parent
        }
        return dir
    }

    private var inferenceSourceDir: URL {
        packageRoot.appendingPathComponent("Sources/PeeknookCore/Inference")
    }

    /// String -> URL constructors that turn a (possibly user-controlled) base into a URL outside the
    /// gate. Whitespace-tolerant so `URL( string :` cannot slip through; `URL(string:relativeTo:)` is
    /// covered by the `URL(string:` prefix. `URLComponents(string:)` is listed because it is the exact
    /// idiom already used elsewhere in-tree (the allowlisted catalog client), so a future engine could
    /// reach for it.
    private static let forbiddenURLConstructors = [
        #"URL\s*\(\s*string\s*:"#,
        #"URLComponents\s*\(\s*string\s*:"#,
    ]

    func testInferenceCodeConstructsURLsOnlyThroughTheGate() throws {
        // The only files allowed to turn a string into a URL inside the inference tree:
        let allowed: Set<String> = [
            "EndpointURLPolicy.swift",    // the gate itself — the one sanctioned URL constructor
            "OllamaCatalogClient.swift",  // model-catalog browsing, not inference egress (its own host handling)
        ]
        let fm = FileManager.default
        let enumerator = try XCTUnwrap(
            fm.enumerator(at: inferenceSourceDir, includingPropertiesForKeys: nil),
            "could not enumerate \(inferenceSourceDir.path) — check the package-root walk"
        )
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let name = url.lastPathComponent
            scanned += 1
            guard !allowed.contains(name) else { continue }
            let code = Self.strippingFullLineComments(try String(contentsOf: url, encoding: .utf8))
            for pattern in Self.forbiddenURLConstructors {
                XCTAssertNil(
                    code.range(of: pattern, options: .regularExpression),
                    """
                    \(name) constructs a URL from a string (matched /\(pattern)/). Every inference URL \
                    must pass through EndpointURLPolicy (the HTTPS/loopback gate) via \
                    InferenceEndpoint.resolvedBaseURL() or the string-baseURL probe path — never a raw \
                    string->URL constructor. If this is a genuinely non-egress URL, add the file to the \
                    allowlist in this test deliberately.
                    """
                )
            }
        }
        XCTAssertGreaterThan(scanned, 5, "expected to scan the inference source tree; the package-root walk likely missed")
    }

    /// Drops whole-line comments (a line whose first non-space is `//`) so a doc comment that merely
    /// mentions a forbidden constructor cannot trip the scan. Leaves code lines — and `http://` inside
    /// string literals — untouched, so it never hides a real call.
    private static func strippingFullLineComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    func testKnownEnginesResolveTheirRequestURLThroughTheSharedAccessor() throws {
        for engineFile in [
            "Ollama/OllamaInferenceEngine.swift",
            "OpenAICompatible/OpenAICompatibleInferenceEngine.swift",
        ] {
            let source = try String(
                contentsOf: inferenceSourceDir.appendingPathComponent(engineFile), encoding: .utf8
            )
            XCTAssertTrue(
                source.contains("resolvedBaseURL("),
                "\(engineFile) must resolve its per-turn request URL through InferenceEndpoint.resolvedBaseURL() (or resolvedBaseURL(expecting:)), the single gate accessor — not by re-deriving the URL itself."
            )
        }
    }
}

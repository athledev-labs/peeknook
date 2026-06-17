// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The accessibility-tree ground ("read the focused window's structure"): a new perception surface that
/// reads the focused window's AX subtree (roles, labels, values, hierarchy) on a user trigger and folds
/// a capped, redacted text outline into a TEXT leg — no image, so it never trips the vision gate, fully
/// local but Accessibility-gated. These tests cover everything except the live `AXUIElement` walk
/// (platform/TCC-only); that path is isolated behind ``AccessibilityTreeReading`` and faked here with
/// ``StubAccessibilityTreeReader`` and an injected trust check.
final class AccessibilityTreeGroundTests: XCTestCase {
    private static let encoding = CaptureEncodingPolicy.resolve(scope: .window, quick: false, quality: .balanced)

    // MARK: - Ground value + permissions

    func testAccessibilityTreeGroundHasStableRawValue() {
        XCTAssertEqual(Ground.accessibilityTree.rawValue, "accessibilityTree")
        XCTAssertEqual(Ground(rawValue: "accessibilityTree"), .accessibilityTree)
        XCTAssertTrue(Ground.allCases.contains(.accessibilityTree))
    }

    func testAccessibilityTreeRequiresAccessibilityPermission() {
        XCTAssertEqual(Ground.accessibilityTree.requiredPermissions, [.accessibility])
    }

    func testAccessibilityTreeIsFoldableAndATextOnlyLeg() {
        XCTAssertTrue(Ground.multiGroundEligible.contains(.accessibilityTree), "a profile can fold in the AX tree")
        XCTAssertTrue(Ground.textOnlyLegs.contains(.accessibilityTree), "the AX outline is text, not an image")
    }

    func testAccessibilityTreeHasAUniqueCaptureLegRank() {
        let ranks = Ground.allCases.map(\.captureLegOrder)
        XCTAssertEqual(Set(ranks).count, ranks.count, "every ground keeps a unique capture rank")
    }

    // MARK: - Serializer caps + truncation

    func testSerializerProducesIndentedRoleLabelValueOutline() {
        let snapshot = AXTreeSnapshot(
            appName: "Mail", windowTitle: "Inbox",
            root: AXTreeNode(role: "AXWindow", label: "Inbox", children: [
                AXTreeNode(role: "AXStaticText", label: "Subject", value: "Hello"),
            ])
        )
        let result = AXTreeSerializer.serialize(snapshot)
        XCTAssertTrue(result.outline.contains("AXWindow(Inbox)"), "the root role + label is emitted")
        XCTAssertTrue(result.outline.contains("  AXStaticText(Subject)=Hello"), "a child is indented with role(label)=value")
        XCTAssertFalse(result.truncated, "a tiny tree is not truncated")
    }

    func testSerializerRespectsNodeCapAndMarksTruncated() {
        let children = (0..<20).map { AXTreeNode(role: "AXButton", label: "b\($0)") }
        let snapshot = AXTreeSnapshot(root: AXTreeNode(role: "AXGroup", children: children))
        let cap = AXTreeCap(maxNodes: 5, maxDepth: 12, maxValueChars: 200, maxTotalChars: 12_000)
        let result = AXTreeSerializer.serialize(snapshot, cap: cap)

        XCTAssertTrue(result.truncated, "exceeding the node cap marks the outline truncated")
        XCTAssertTrue(result.outline.contains(AXTreeSerializer.truncationMarker), "the truncation marker is appended")
        // Root + at most 4 buttons = 5 emitted nodes (the cap), so b4..b19 must not all appear.
        XCTAssertFalse(result.outline.contains("b19"), "nodes past the cap are dropped")
    }

    func testSerializerRespectsDepthCapAndMarksTruncated() {
        // A chain deeper than the cap: depth 0..3, cap depth at 1.
        let deep = AXTreeNode(role: "A", children: [
            AXTreeNode(role: "B", children: [
                AXTreeNode(role: "C", children: [AXTreeNode(role: "D")]),
            ]),
        ])
        let cap = AXTreeCap(maxNodes: 400, maxDepth: 1, maxValueChars: 200, maxTotalChars: 12_000)
        let result = AXTreeSerializer.serialize(AXTreeSnapshot(root: deep), cap: cap)

        XCTAssertTrue(result.truncated, "descending past the depth cap marks truncated")
        XCTAssertTrue(result.outline.contains("A"))
        XCTAssertTrue(result.outline.contains("B"))
        XCTAssertFalse(result.outline.contains("\n    C"), "a node past the depth cap is not emitted")
    }

    func testSerializerElidesAnOversizedValueAndHardCapsTotal() {
        let long = String(repeating: "x", count: 1000)
        let snapshot = AXTreeSnapshot(root: AXTreeNode(role: "AXTextField", label: "Notes", value: long))
        let cap = AXTreeCap(maxNodes: 400, maxDepth: 12, maxValueChars: 20, maxTotalChars: 12_000)
        let result = AXTreeSerializer.serialize(snapshot, cap: cap)

        XCTAssertTrue(result.truncated, "eliding a value marks truncated")
        XCTAssertFalse(result.outline.contains(long), "the full oversized value is never emitted")
        XCTAssertTrue(result.outline.contains("…"), "the elided value is marked")
    }

    func testSerializerHardCapsTotalCharacters() {
        let children = (0..<200).map { AXTreeNode(role: "AXStaticText", label: "row\($0)", value: String(repeating: "y", count: 50)) }
        let snapshot = AXTreeSnapshot(root: AXTreeNode(role: "AXList", children: children))
        let cap = AXTreeCap(maxNodes: 400, maxDepth: 12, maxValueChars: 200, maxTotalChars: 300)
        let result = AXTreeSerializer.serialize(snapshot, cap: cap)

        XCTAssertTrue(result.truncated, "exceeding the total-char cap marks truncated")
        // Body capped at 300 chars + the appended truncation marker line.
        XCTAssertLessThanOrEqual(result.outline.count, 300 + AXTreeSerializer.truncationMarker.count + 1)
    }

    func testSerializerCarriesThroughSnapshotTruncation() {
        let snapshot = AXTreeSnapshot(root: AXTreeNode(role: "AXWindow"), truncated: true)
        let result = AXTreeSerializer.serialize(snapshot)
        XCTAssertTrue(result.truncated, "a snapshot the walk already truncated stays truncated")
    }

    // MARK: - Per-node secure-value redaction (keeps structure, drops the value)

    func testSecureNodeKeepsRoleAndLabelButDropsValue() async throws {
        let provider = AccessibilityTreeCaptureProvider(reader: StubAccessibilityTreeReader(), isTrusted: { true })
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
        let outline = try XCTUnwrap(result.text)

        // The secure field's structure survives, but its value never leaves the Mac.
        XCTAssertTrue(outline.contains("AXTextField(Password)"), "the secure node keeps its role + label")
        XCTAssertFalse(outline.contains("hunter2-secret"), "the secure value is dropped")
        XCTAssertTrue(outline.contains(SensitiveContentPolicy.redactionToken), "the dropped value is replaced with a marker")
        // A non-secure field's value passes through untouched.
        XCTAssertTrue(outline.contains("AXTextField(Search)=release notes"), "a plain value survives")
    }

    func testSecureValueRedactionIsPureAndRecursive() {
        let snapshot = AXTreeSnapshot(root: AXTreeNode(role: "AXGroup", children: [
            AXTreeNode(role: "AXTextField", subrole: "AXSecureTextField", label: "Pass", value: "topsecret"),
            AXTreeNode(role: "AXTextField", label: "Plain", value: "visible"),
        ]))
        let redacted = AccessibilityTreeCaptureProvider.redactingSecureValues(in: snapshot)
        let secure = redacted.root.children[0]
        let plain = redacted.root.children[1]
        XCTAssertEqual(secure.value, SensitiveContentPolicy.redactionToken, "the secure value is masked")
        XCTAssertEqual(secure.label, "Pass", "the secure node keeps its label")
        XCTAssertEqual(plain.value, "visible", "a plain value is untouched")
    }

    // MARK: - Outline secret redaction (a secret in a NON-secure field is masked)

    func testTokenInANonSecureFieldIsRedactedFromTheOutline() async throws {
        let snapshot = AXTreeSnapshot(
            appName: "Notes", windowTitle: "Scratch",
            root: AXTreeNode(role: "AXWindow", label: "Scratch", children: [
                // A JWT/sk- token sitting in a PLAIN text field — not a secure field, so per-node
                // redaction would not catch it; the outline span redaction must.
                AXTreeNode(role: "AXTextArea", label: "Body", value: "key sk-ABCDEFGHIJKLMNOPQRSTUVWX here"),
            ])
        )
        let provider = AccessibilityTreeCaptureProvider(
            reader: StubAccessibilityTreeReader(snapshot: snapshot), isTrusted: { true }
        )
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
        let outline = try XCTUnwrap(result.text)

        XCTAssertFalse(outline.contains("sk-ABCDEFGHIJKLMNOPQRSTUVWX"), "a token in a plain field must be masked")
        XCTAssertTrue(outline.contains(SensitiveContentPolicy.redactionToken), "the masked token leaves a marker")
        XCTAssertTrue(outline.contains("AXTextArea(Body)"), "the field's structure still rides")
    }

    // MARK: - Provider policy (text leg, no vision; trust gate)

    func testProviderReturnsTextOnlyLegWithNoImage() async throws {
        let provider = AccessibilityTreeCaptureProvider(reader: StubAccessibilityTreeReader(), isTrusted: { true })
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)

        XCTAssertEqual(result.ground, .accessibilityTree)
        XCTAssertEqual(result.appName, "Mail", "the window's app identity rides the leg")
        XCTAssertEqual(result.windowTitle, "Inbox")
        XCTAssertNil(result.screenshotBase64, "an outline carries no image")
        XCTAssertNil(result.screenshotBlobID)
        XCTAssertFalse(result.hasVision, "no image means the vision gate must never engage")
    }

    func testProviderThrowsPermissionRequiredWhenNotTrusted() async {
        let provider = AccessibilityTreeCaptureProvider(reader: StubAccessibilityTreeReader(), isTrusted: { false })
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("an untrusted process must throw, not read the AX tree")
        } catch {
            XCTAssertEqual(error as? CaptureError, .permissionRequired("Accessibility"))
        }
    }

    func testProviderSurfacesReaderError() async {
        let provider = AccessibilityTreeCaptureProvider(
            reader: StubAccessibilityTreeReader(error: .failed("no focused window")), isTrusted: { true }
        )
        do {
            _ = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
            XCTFail("a reader failure must propagate")
        } catch {
            XCTAssertEqual(error as? CaptureError, .failed("no focused window"))
        }
    }

    // MARK: - Modality resolution

    func testAccessibilityTreeResolvesAsTranscriptModality() {
        XCTAssertEqual(MediaPayload.Kind.resolved(for: .accessibilityTree), .transcript)
    }

    // MARK: - Registry wiring

    func testTestingDependenciesRegisterAccessibilityTreeProvider() async throws {
        let deps = await PeeknookDependencies.testing()
        let provider = try deps.captureRegistry.resolve(.accessibilityTree)
        XCTAssertTrue(provider is AccessibilityTreeCaptureProvider)
        let result = try await provider.capture(scope: .window, quick: false, encoding: Self.encoding)
        XCTAssertEqual(result.ground, .accessibilityTree)
        XCTAssertFalse(result.hasVision)
    }

    // MARK: - Single-leg prompt (an accessibility outline, not a screenshot)

    func testOutlineLegPromptDescribesAccessibilityTreeNotScreenshot() {
        let capture = CaptureResult(
            text: "AXWindow(Inbox)\n  AXButton(Reply)",
            sourceLabel: "Accessibility tree",
            ground: .accessibilityTree
        )
        let message = PromptBuilder.captureUserMessage(capture: capture, assembly: PromptAssembly(answerDepth: .deep))

        XCTAssertTrue(message.contains("Ground: accessibility tree"), "the AX ground is named")
        XCTAssertTrue(message.contains("Accessibility outline of the focused window:"), "the text is labelled as an outline")
        XCTAssertTrue(message.contains("AXButton(Reply)"), "the outline rides in the message")
        XCTAssertFalse(message.contains("A screenshot is attached"), "no screenshot is claimed")
        XCTAssertFalse(message.contains("rely on the screenshot"), "an image-less leg must not point at a screenshot")
        XCTAssertFalse(message.contains("prefer the screenshot"), "the outline is primary, not supplementary")
    }

    // MARK: - Multi-ground prompt (screen image + accessibility outline)

    func testMultiGroundPromptNamesScreenshotAndOutlineCorrectly() {
        let screen = MediaPayload(
            capture: CaptureResult(text: "Form", sourceLabel: "Safari", appName: "Safari", screenshotBase64: "SCRb64", ground: .screen),
            kind: .image,
            imageBase64: "SCRb64"
        )
        let ax = MediaPayload(
            capture: CaptureResult(text: "AXWindow(Login)\n  AXTextField(Email)", sourceLabel: "Accessibility tree", ground: .accessibilityTree),
            kind: .transcript,
            imageBase64: nil
        )
        let message = PromptBuilder.multiGroundUserMessage(
            payloads: [screen, ax],
            assembly: PromptAssembly(answerDepth: .deep)
        )

        XCTAssertTrue(message.contains("(1 views, one question)"), "only the one image view is counted")
        XCTAssertTrue(message.contains("SCREENSHOT"), "the screen leg is named as a screenshot")
        XCTAssertTrue(message.contains("Transcript of the accessibility outline:"), "the AX leg reads as a text block")
        XCTAssertTrue(message.contains("AXTextField(Email)"), "the outline text is present")
        XCTAssertFalse(
            message.contains("Supplementary extracted text from the accessibility outline"),
            "the outline must not be framed as supplement-to-image"
        )
    }

    // MARK: - Tolerant decoding (a persisted AX leg survives)

    func testAccessibilityTreeGroundRoundTripsThroughJSON() throws {
        let capture = CaptureResult(text: "AXWindow(Doc)", sourceLabel: "Accessibility tree", ground: .accessibilityTree)
        let decoded = try JSONDecoder().decode(CaptureResult.self, from: JSONEncoder().encode(capture))
        XCTAssertEqual(decoded.ground, .accessibilityTree)
        XCTAssertEqual(decoded.text, "AXWindow(Doc)")
    }
}

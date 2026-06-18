// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import PeeknookCore

/// The `PeekSettingsController` tool helpers: synchronous URL validation for the editor's inline note
/// and the user-triggered reachability probe. Both route the URL through ``EndpointURLPolicy`` (the same
/// HTTPS gate as inference); a tool spec carries no insecure-HTTP opt-in, so a remote http:// tool is
/// always rejected. The probe uses an injected stub, so no test touches the network.
@MainActor
final class ToolProfileEditingTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "peeknook.tests.toolProfileEditing")!
        defaults.removePersistentDomain(forName: "peeknook.tests.toolProfileEditing")
    }

    private func makeController(probe: any ToolReachabilityProbing) -> PeekSettingsController {
        let orchestrator = SessionOrchestrator(
            settings: PeeknookSettings(textModel: "x"),
            captureRegistry: GroundRegistry([.screen: StubCaptureProvider(sampleText: "s")]),
            inference: MockInferenceEngine(tokens: ["a"])
        )
        let setup = SetupCoordinator(settings: orchestrator.settings, defaults: defaults)
        return PeekSettingsController(
            orchestrator: orchestrator,
            setup: setup,
            defaults: defaults,
            inferenceRegistry: .uniform(MockInferenceEngine(tokens: ["a"])),
            toolProbe: probe
        )
    }

    // MARK: - URL validation

    func testToolURLValidityAcceptsLoopbackHTTP() {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        XCTAssertEqual(controller.toolURLValidity("http://127.0.0.1:7000"), .valid)
        XCTAssertEqual(controller.toolURLValidity("http://localhost:7000/run"), .valid)
    }

    func testToolURLValidityRejectsRemoteHTTP() {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        XCTAssertEqual(
            controller.toolURLValidity("http://example.com:7000"), .insecureRemote,
            "a remote http:// tool is rejected: a tool spec has no insecure-HTTP opt-in"
        )
    }

    func testToolURLValidityAcceptsRemoteHTTPS() {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        XCTAssertEqual(controller.toolURLValidity("https://tools.example.com/run"), .valid)
    }

    func testToolURLValidityEmptyIsAllowedInProgress() {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        XCTAssertEqual(controller.toolURLValidity("   "), .empty)
    }

    func testToolURLValidityRejectsUnsupportedScheme() {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        XCTAssertEqual(controller.toolURLValidity("ftp://example.com"), .invalid)
    }

    // MARK: - Reachability probe

    func testToolReachableReturnsReachableWhenProbeAnswers() async {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        let health = await controller.toolReachable(ToolSpec(transport: .http, url: "http://127.0.0.1:7000"))
        XCTAssertEqual(health, .reachable)
    }

    func testToolReachableReturnsUnreachableWhenProbeDoesNotAnswer() async {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: false))
        let health = await controller.toolReachable(ToolSpec(transport: .http, url: "http://127.0.0.1:7000"))
        XCTAssertEqual(health, .unreachable)
    }

    func testToolReachableRejectsRemoteHTTPBeforeProbing() async {
        // The probe would say reachable, but the HTTPS gate must reject a remote http:// tool FIRST.
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        let health = await controller.toolReachable(ToolSpec(transport: .http, url: "http://example.com:7000"))
        XCTAssertEqual(health, .rejected)
    }

    func testToolReachableIsUnconfiguredWithoutURL() async {
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        let health = await controller.toolReachable(ToolSpec(transport: .http, url: ""))
        XCTAssertEqual(health, .unconfigured)
    }

    func testToolReachableIsUnconfiguredForCommandTransport() async {
        // A command tool is unreachable over HTTP and never created by the signed UI; the probe declines.
        let controller = makeController(probe: StubToolReachabilityProbe(reachable: true))
        let health = await controller.toolReachable(ToolSpec(transport: .command, command: "/bin/echo"))
        XCTAssertEqual(health, .unconfigured)
    }
}

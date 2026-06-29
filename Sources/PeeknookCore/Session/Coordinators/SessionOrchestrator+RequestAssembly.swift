// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The outbound ``InferenceRequest`` plus the routing context the caller needs after assembly.
struct AssembledRequest {
    let request: InferenceRequest
    /// The resolved model + endpoint. Exposed because the caller streams and records usage off it and
    /// — load-bearing — maps errors via `route.model.backend`, which `request.model` (a bare tag
    /// `String`) cannot recover. The request is built FROM this route, so the two never disagree.
    let route: RoleResolution
    /// Secret spans stripped from the SENT text legs (0 on a local/loopback non-cloud turn, where no
    /// inspection runs). The answer pass surfaces this in a notice; the follow-up suggestion pass
    /// ignores it because the answer pass already surfaced it for the turn.
    let redactedSecretCount: Int
}

@MainActor
extension SessionOrchestrator {
    /// The single place a turn's request is assembled from a ``ModelRole``. It resolves the role to its
    /// model + endpoint route, derives the ONE remote-egress redaction rule (a ``RedactionContext`` only
    /// when the route streams to a remote host or an Ollama `:cloud` tag, else `nil` so the assembled
    /// messages stay byte-identical), lets the caller fold the messages with that redaction, and wraps
    /// the request envelope off the active profile + settings.
    ///
    /// `buildMessages` receives the redaction context (or `nil`) and MUST thread it into
    /// ``InferenceMessageBuilder/inferenceMessages(from:webLookup:translation:policy:imageBase64ByTurnID:redaction:)``;
    /// the seam cannot force this, so a remote-route caller that drops it would egress unredacted.
    /// `RedactionContext` is a reference type, so the create-here → mutate-inside-`buildMessages` →
    /// read-the-tally ordering is preserved by the closure shape. The answer turn and the follow-up
    /// suggestion pass both assemble here, so the "strip secrets before remote egress" rule cannot fork
    /// between them; the caption sink will route through here too, layering its own local-only egress
    /// policy on top (the text redactor does not cover conversational audio PII).
    func assembleRequest(
        role: ModelRole,
        quickMode: Bool,
        buildMessages: (RedactionContext?) -> [InferenceMessage]
    ) -> AssembledRequest {
        let route = routing(for: role)
        let redaction = route.endpoint.isRemoteEgress(modelTag: route.model.tag)
            ? RedactionContext()
            : nil
        let messages = buildMessages(redaction)
        let request = InferenceRequest(
            mode: settings.mode,
            agentSystemAppendix: activeAgentAppendix,
            profileTemplate: activeProfileTemplate,
            messages: messages,
            model: route.model.tag,
            endpoint: route.endpoint,
            quickMode: quickMode
        )
        return AssembledRequest(
            request: request,
            route: route,
            redactedSecretCount: redaction?.hitCount ?? 0
        )
    }
}

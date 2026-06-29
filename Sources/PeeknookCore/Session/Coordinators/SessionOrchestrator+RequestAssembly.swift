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
    /// `routeOverride` lets a caller pin a PRE-RESOLVED route instead of resolving `role` live. The
    /// caption sink uses it to reuse the route it froze at arm (after the local-only egress gate passed),
    /// so a mid-session model/profile change can't drift the route — and thus can't bypass that gate —
    /// while a tap is running. When nil (the answer and suggestion passes), the route resolves from `role`
    /// exactly as before.
    func assembleRequest(
        role: ModelRole,
        quickMode: Bool,
        routeOverride: RoleResolution? = nil,
        buildMessages: (RedactionContext?) -> [InferenceMessage]
    ) -> AssembledRequest {
        let route = routeOverride ?? routing(for: role)
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

    // MARK: - Caption routing

    /// The role a caption's translate pass routes to. A caption is a text→text translation that needs no
    /// vision weights, so it PREFERS a configured LOCAL text-only model; it falls back to the profile's
    /// vision model otherwise (via the reserved `.fastVision` slot — semantically "a fast model for the
    /// caption", which resolves to the active answer model today). The local-only egress gate is applied
    /// to whichever route this resolves, independently of the role — a remote text-only model is skipped
    /// here precisely so a caption never silently picks a remote route over a local vision one.
    var captionRole: ModelRole {
        let textOnly = routing(for: .textOnly)
        if settings.hasUsableTextOnlyModel,
           !textOnly.endpoint.isRemoteEgress(modelTag: textOnly.model.tag) {
            return .textOnly
        }
        return .fastVision
    }

    /// The translate directive a caption carries, projected from the active profile's output config (the
    /// same projection the answer turn uses). Nil unless a target language is set — and a nil here is the
    /// `arm()` preguard that refuses to caption without one. Keyed on the PRESENCE of the target, never
    /// its value (invariant 1).
    var captionTranslationDirective: TranslationDirective? {
        resolvedActiveProfile.outputConfig?.translationDirective
    }

    /// The on-device source locale for the transcription tap, resolved from the active profile's free-text
    /// source-language label via the pure ``SpeechLocaleResolver`` (against the system's known locales).
    /// Falls back to ``Locale/current`` when no label is set (auto) or the label can't be mapped; the
    /// production transcriber re-validates against the device's actual speech-supported locales and throws
    /// ``SpeechRecognitionError/onDeviceUnavailable`` when the dictation pack is missing, which surfaces as
    /// the typed caption failure card.
    var captionSourceLocale: Locale {
        SpeechLocaleResolver.locale(
            forLanguageLabel: resolvedActiveProfile.outputConfig?.sourceLanguage,
            supported: Self.captionLocaleUniverse
        ) ?? .current
    }

    /// The candidate locale set the source-language label is resolved against — every locale the system
    /// knows about. Computed once: `Locale.availableIdentifiers` is ~stable and the resolution runs only
    /// at arm. The device's narrower SPEECH-supported set is the production transcriber's authority.
    static let captionLocaleUniverse: [Locale] = Locale.availableIdentifiers.map(Locale.init(identifier:))
}

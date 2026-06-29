// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Carries secret-redaction across the message build for a remote/`:cloud` turn. When present, the
/// prompt builder replaces secret spans in the SENT text legs (transcript/clipboard primary text and
/// supplementary extracted text) with a fixed token and tallies the count here; the archived
/// ``ChatTurn`` and the on-screen conversation keep the original text untouched. The screenshot bitmap
/// is out of scope — only text legs are inspected. `nil` (the local, non-cloud path) means no
/// inspection at all, so the assembled messages stay byte-identical to before.
///
/// A reference type so the prompt builder's static, value-returning functions can accumulate the hit
/// count across every message in one turn without changing their return shape.
final class RedactionContext {
    let policy: SensitiveContentPolicy
    private(set) var hitCount = 0

    init(policy: SensitiveContentPolicy = SensitiveContentPolicy()) {
        self.policy = policy
    }

    /// Redacts one text leg headed for the remote model, tallying any stripped spans. Returns the
    /// original string unchanged (and adds nothing to the count) when it carries no secrets.
    func redact(_ text: String) -> String {
        let result = policy.redactedForRemoteInference(text: text)
        hitCount += result.hitCount
        return result.text
    }
}

/// Pure mapping from the display conversation to the model's message list. Takes the per-turn
/// inputs (`quickMode`, `sessionBrief`) as plain values so it has no orchestrator dependency and the
/// message logic is directly testable. The inference and suggestion coordinators both build their
/// request messages through this type, so the folding, group-atomic replay, and grounding rules can
/// never diverge between the answer pass and the follow-up pass.
struct InferenceMessageBuilder {
    /// Answer terseness for this turn — feeds ``AnswerDepth``.
    let quickMode: Bool
    /// The user's optional session brief, already nil when empty.
    let sessionBrief: String?

    init(quickMode: Bool, sessionBrief: String?) {
        self.quickMode = quickMode
        self.sessionBrief = sessionBrief
    }

    private func promptAssembly(continuingSession: Bool) -> PromptAssembly {
        PromptAssembly(
            answerDepth: AnswerDepth(quickMode: quickMode),
            sessionBrief: sessionBrief,
            continuingSession: continuingSession
        )
    }

    /// The image legs of the turn just committed: the trailing run of image turns sharing the final
    /// image turn's `compositeGroupID` (a standalone capture is a one-leg group). Lets the web-lookup
    /// gate find a screen leg even when the turn ran on a non-screen leg (e.g. a composite's camera
    /// leg). A `compositeGroupID` is a fresh UUID per group, so filtering by it never crosses groups.
    func latestTurnLegs(in conversation: [ChatTurn]) -> [CaptureResult] {
        let imageTurns = conversation.filter(\.isImage)
        guard let last = imageTurns.last else { return [] }
        let legs = last.compositeGroupID.map { group in
            imageTurns.filter { $0.compositeGroupID == group }
        } ?? [last]
        return legs.compactMap { turn in
            if case .image(let capture) = turn.kind { return capture }
            return nil
        }
    }

    /// Groups image turns into replay units: a multi-ground group's legs (consecutive turns sharing a
    /// `compositeGroupID`) form ONE unit; standalone images are their own unit. Order preserved, so
    /// `maxImagePayloads` budgets whole questions and never replays half a group.
    func imagePayloadUnits(_ imageTurns: [ChatTurn]) -> [[ChatTurn]] {
        var units: [[ChatTurn]] = []
        var previousGroup: UUID?
        for turn in imageTurns {
            if let group = turn.compositeGroupID, group == previousGroup, !units.isEmpty {
                units[units.count - 1].append(turn)
            } else {
                units.append([turn])
            }
            previousGroup = turn.compositeGroupID
        }
        return units
    }

    /// Maps the display conversation to the model's message list: each image unit becomes one
    /// grounded user message. A multi-ground unit (e.g. screen + camera, or any N grounds) folds all
    /// its legs into a single message carrying every leg's image, in order; standalone images are
    /// byte-identical to before. Only the latest `policy.maxImagePayloads` units ride as base64
    /// payloads; older ones keep text grounding.
    func inferenceMessages(
        from conversation: [ChatTurn],
        webLookup: WebLookupSnapshot? = nil,
        translation: TranslationDirective? = nil,
        policy: InferenceReplayPolicy = .inference,
        imageBase64ByTurnID: [Int: String] = [:],
        redaction: RedactionContext? = nil
    ) -> [InferenceMessage] {
        let units = imagePayloadUnits(conversation.filter(\.isImage))
        let replayImageIDs = Set(units.suffix(policy.maxImagePayloads).flatMap { $0.map(\.id) })
        let lastUnitIDs = Set(units.last?.map(\.id) ?? [])
        // Per-leg unit position (0-based among image units) and the representative ("first") leg of
        // each unit — the one we emit; the other legs of a composite were already folded into it.
        var unitIndexByID: [Int: Int] = [:]
        var firstLegIDs = Set<Int>()
        for (index, unit) in units.enumerated() {
            let ordered = unit.sorted { $0.id < $1.id }
            if let first = ordered.first { firstLegIDs.insert(first.id) }
            for leg in unit { unitIndexByID[leg.id] = index }
        }

        var messages: [InferenceMessage] = []
        for turn in conversation {
            switch turn.kind {
            case .image(let capture):
                guard firstLegIDs.contains(turn.id) else { continue } // folded composite leg, already emitted
                let unitIndex = unitIndexByID[turn.id] ?? 0
                let assembly = promptAssembly(continuingSession: unitIndex > 0)
                let isLastUnit = lastUnitIDs.contains(turn.id)
                let lookup = isLastUnit ? webLookup : nil
                // Translate is a directive for the CURRENT capture only: it rides the last image unit's
                // message, never a replayed prior screenshot, so resuming a thread re-translates nothing.
                let turnTranslation = isLastUnit ? translation : nil
                let unit = units[unitIndex].sorted { $0.id < $1.id }

                if unit.count > 1 {
                    // Multi-ground turn: project each leg into a MediaPayload and fold them into one
                    // message, named in order. Replay is group-atomic, so the images ride only when
                    // the whole unit is in the replay window (otherwise the legs keep text grounding).
                    let includeImages = unit.allSatisfy { replayImageIDs.contains($0.id) }
                    let payloads: [MediaPayload] = unit.compactMap { leg in
                        guard case .image(let c) = leg.kind else { return nil }
                        // A transcript leg (e.g. system audio) carries no image — its text is folded in
                        // by the prompt builder, so it never gets a base64 payload even inside the budget.
                        let kind = MediaPayload.Kind.resolved(for: c.ground)
                        let base64 = (kind == .image && includeImages)
                            ? (imageBase64ByTurnID[leg.id] ?? c.screenshotBase64) : nil
                        return MediaPayload(capture: c, kind: kind, imageBase64: base64)
                    }
                    messages.append(InferenceMessage(
                        role: .user,
                        text: PromptBuilder.multiGroundUserMessage(
                            payloads: payloads, assembly: assembly, webLookup: lookup,
                            translation: turnTranslation, redaction: redaction
                        ),
                        imagesBase64: payloads.compactMap(\.imageBase64)
                    ))
                } else {
                    let includeImage = replayImageIDs.contains(turn.id)
                    messages.append(InferenceMessage(
                        role: .user,
                        text: PromptBuilder.captureUserMessage(
                            capture: capture,
                            assembly: assembly,
                            webLookup: lookup,
                            question: turn.question,   // a live-promoted frame folds its note into this message
                            translation: turnTranslation,
                            redaction: redaction
                        ),
                        imageBase64: includeImage ? (imageBase64ByTurnID[turn.id] ?? capture.screenshotBase64) : nil
                    ))
                }
            case .user(let text):
                messages.append(InferenceMessage(
                    role: .user,
                    text: PromptBuilder.followUpUserMessage(
                        question: text,
                        assembly: promptAssembly(continuingSession: false)
                    )
                ))
            case .assistant(let text):
                messages.append(InferenceMessage(role: .assistant, text: text))
            }
        }
        return messages
    }
}

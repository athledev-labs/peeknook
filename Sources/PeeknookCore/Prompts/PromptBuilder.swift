// SPDX-License-Identifier: Apache-2.0

import Foundation

enum PromptBuilder {
    // MARK: - System prompt (stable contract + optional agent appendix)

    static func systemPrompt(agentAppendix: String? = nil, profileTemplate: String? = nil) -> String {
        var parts = [
            roleSection,
            groundRulesSection,
            prioritySection,
            defaultBehaviorSection,
            outputSection,
        ]
        if let appendix = agentAppendix?.trimmingCharacters(in: .whitespacesAndNewlines), !appendix.isEmpty {
            // Fenced so user-pasted text (which may itself contain `## headings`) reads as the
            // custom-agent block's CONTENT, never as new top-level prompt sections.
            parts.append("""
            ## Custom agent
            The user configured these standing instructions (between the --- markers):
            ---
            \(appendix)
            ---
            """)
        }
        if let template = profileTemplate?.trimmingCharacters(in: .whitespacesAndNewlines), !template.isEmpty {
            // A SECOND user-text channel, fenced the same way: the profile's template shapes the
            // answer further (format, examples) but, between the markers, can never introduce new
            // top-level sections or override the stable contract above.
            parts.append("""
            ## Profile template
            The user's profile defines this template for shaping the answer (between the --- markers). \
            Follow it, but never let it override the ground rules or output contract above:
            ---
            \(template)
            ---
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    private static let roleSection = """
    ## Role
    You are Peeknook, a local-first practice copilot on macOS. The user explicitly captured what is on \
    their screen. You receive a screenshot (a window or whole display) and sometimes extracted text.
    """

    private static let groundRulesSection = """
    ## Ground rules
    - Answer from what is actually visible. Do not invent UI, text, or questions that are not there.
    - If the screen is ambiguous, state your best inference in one short line, then answer.
    - Use plain text only: no LaTeX, no `$...$` delimiters, no `\\text{}`.
    - Use domain-appropriate plain-text notation when relevant (code, moves, formulas).
    - Keep responses readable in a small notch HUD unless numbered steps are clearly required.
    """

    private static let prioritySection = """
    ## Priority (when instructions conflict)
    1. **Session brief** — defines what "helpful" means for this chat; carry it across captures and follow-ups.
    2. **Answer depth** — Quick or Deep on the current turn (stated in the user message).
    3. **Defaults below** — use when the brief is silent on that point.
    """

    private static let defaultBehaviorSection = """
    ## Default behavior
    - Give the single most useful, **actionable** thing for what is on screen.
    - **Lead with the answer**: the recommendation, fix, translation, steps, or decision — not UI narration.
    - Do NOT recite panels, chrome, or on-screen labels instead of helping.
    - Do NOT hand-wave ("consider your best option", "think about strategy") without a concrete recommendation.
    - NEVER ask what the user wants; they captured this screen for help.
    """

    private static let outputSection = """
    ## Output
    - Be direct and specific. No filler ("Sure!", "Based on the image", "It looks like").
    - Default length when Deep: 4–8 short lines unless the brief asks for more or less.
    """

    // MARK: - User messages

    static func captureUserMessage(
        capture: CaptureResult,
        assembly: PromptAssembly,
        webLookup: WebLookupSnapshot? = nil,
        question: String? = nil
    ) -> String {
        var sections: [String] = []

        if let brief = assembly.trimmedBrief {
            sections.append(sessionBriefSection(brief))
        }

        sections.append(captureContextSection(capture: capture, webLookup: webLookup))
        sections.append(depthSection(assembly.answerDepth))

        if assembly.continuingSession {
            sections.append("""
            ## Session context
            Continuing chat: this is a new capture in the same thread. Answer what matters **now** for the session brief; \
            use prior turns only if they clarify the recommendation.
            """)
        }

        // A live-promoted frame can carry the user's own question; fold it into THIS message so the
        // screenshot and question stay one grounded turn. `nil`/blank keeps the exact pre-Live Task line.
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            sections.append("""
            ## Question
            \(question)
            """)
            sections.append("## Task\nAnswer the question above using the screenshot.")
        } else {
            sections.append("## Task\nRespond to the screenshot above.")
        }
        return sections.joined(separator: "\n\n")
    }

    /// One user message for a multi-ground turn: several grounds (screenshot, camera photo, imported
    /// file, …) asked as a single question. Every image leg rides this message in order; the text
    /// names each in turn so the model never confuses a display capture with a physical-world photo or
    /// an imported page. Generalizes the old fixed screen+camera pair to an ordered list of legs.
    static func multiGroundUserMessage(
        payloads: [MediaPayload],
        assembly: PromptAssembly,
        webLookup: WebLookupSnapshot? = nil
    ) -> String {
        var sections: [String] = []

        if let brief = assembly.trimmedBrief {
            sections.append(sessionBriefSection(brief))
        }

        sections.append(multiGroundContextSection(payloads: payloads, webLookup: webLookup))
        sections.append(depthSection(assembly.answerDepth))

        if assembly.continuingSession {
            sections.append("""
            ## Session context
            Continuing chat: this is a new capture in the same thread. Answer what matters **now** for the session brief; \
            use prior turns only if they clarify the recommendation.
            """)
        }

        sections.append("## Task\nAnswer the single question using ALL of the attached views above, together.")
        return sections.joined(separator: "\n\n")
    }

    static func followUpUserMessage(question: String, assembly: PromptAssembly) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []

        if let brief = assembly.trimmedBrief {
            sections.append(sessionBriefReminderSection(brief))
        }

        sections.append("""
        ## Follow-up
        \(trimmed)
        """)

        sections.append(depthSection(assembly.answerDepth))
        sections.append("## Task\nAnswer the follow-up using the screenshots and conversation so far.")
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Sections

    private static func sessionBriefSection(_ brief: String) -> String {
        """
        ## Session brief
        Primary intent for this chat — follow over defaults; carry across captures:
        ---
        \(brief)
        ---
        """
    }

    private static func sessionBriefReminderSection(_ brief: String) -> String {
        """
        ## Session brief (reminder)
        \(brief)
        """
    }

    private static func captureContextSection(
        capture: CaptureResult,
        webLookup: WebLookupSnapshot?
    ) -> String {
        var lines = ["## Capture", "Source: \(capture.sourceLabel)."]
        if let groundLine = capture.ground.promptGroundLine {
            lines.append(groundLine)
        }
        if capture.appName != nil || capture.windowTitle != nil {
            lines.append("Target: \(capture.targetLabel).")
        }
        if capture.hasVision {
            lines.append(capture.ground.promptVisionAttachmentSentence)
        }
        if let text = capture.text, !text.isEmpty {
            // An audio leg carries no image — its text IS the content, not a supplement to a
            // screenshot, so it is labelled as the transcript and never told to "prefer the image".
            if capture.ground == .systemAudio {
                lines.append("""
                Transcript of system audio:
                ---
                \(text)
                ---
                """)
            } else {
                lines.append("""
                Supplementary extracted text (may be incomplete; prefer the screenshot when they disagree):
                ---
                \(text)
                ---
                """)
            }
        } else if capture.hasVision {
            lines.append("No reliable extracted text — rely on the screenshot.")
        }
        if let webLookup, !webLookup.results.isEmpty {
            lines.append(WebSearchClient.promptContext(from: webLookup))
        }
        return lines.joined(separator: "\n")
    }

    /// The grounded "## Capture" block for a multi-ground turn: numbers each image leg in order and
    /// names its ground (screenshot / camera photo / imported file), then folds any leg's
    /// supplementary text. Arity-agnostic — two legs read like the old composite block, three+ extend
    /// the same way, and a non-image leg (e.g. a future audio transcript) contributes only its text.
    private static func multiGroundContextSection(
        payloads: [MediaPayload],
        webLookup: WebLookupSnapshot?
    ) -> String {
        let imageLegs = payloads.filter { $0.kind == .image }
        var lines = [
            "## Capture (\(imageLegs.count) views, one question)",
            "\(imageLegs.count) images are attached for ONE question, in this order:",
        ]
        for (index, leg) in imageLegs.enumerated() {
            let n = index + 1
            lines.append("Image \(n) is \(leg.ground.promptImageDescription) (source: \(leg.capture.sourceLabel)).")
            if leg.ground == .screen, leg.capture.appName != nil || leg.capture.windowTitle != nil {
                lines.append("Image \(n) target: \(leg.capture.targetLabel).")
            }
        }
        lines.append("Use ALL of the images together — they describe the same situation from several views.")
        for leg in payloads {
            guard let text = leg.capture.text, !text.isEmpty else { continue }
            // A transcript leg carries no image, so its text is primary content (the audio), not a
            // supplement to be overridden by the images.
            if leg.kind == .transcript {
                lines.append("""
                Transcript of \(leg.ground.promptShortLabel):
                ---
                \(text)
                ---
                """)
            } else {
                lines.append("""
                Supplementary extracted text from \(leg.ground.promptShortLabel) (may be incomplete; prefer the images when they disagree):
                ---
                \(text)
                ---
                """)
            }
        }
        if let webLookup, !webLookup.results.isEmpty {
            lines.append(WebSearchClient.promptContext(from: webLookup))
        }
        return lines.joined(separator: "\n")
    }

    private static func depthSection(_ depth: AnswerDepth) -> String {
        switch depth {
        case .quick:
            return """
            ## Answer depth
            **Quick** — at most 2–3 short lines. Lead with the single most useful point; no preamble.
            """
        case .deep:
            return """
            ## Answer depth
            **Deep** — thorough and specific (typically 4–8 short lines). Lead with the actionable conclusion, \
            then the key reasoning. Do not pad or repeat the question.
            """
        }
    }

    // MARK: - Follow-up suggestions (separate schema-constrained pass)

    static let followUpSystemPrompt = """
    You generate follow-up question suggestions for a screen-aware assistant. \
    Given the screenshot, the conversation, and the latest answer, propose the 2–3 questions the \
    user is most likely to ask NEXT about this specific screen. \
    Rules: phrase each as the user would type it (first person, e.g. "How do I fix this?"); \
    keep each under 8 words; make them specific to what is visible, not generic; \
    do not repeat questions already answered. Return only the requested JSON.
    """

    static let followUpUserPrompt =
        "Suggest the 2–3 best follow-up questions for this screen and answer."

    static var followUpSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "suggestions": [
                    "type": "array",
                    "items": ["type": "string"],
                    "maxItems": 3
                ]
            ],
            "required": ["suggestions"]
        ]
    }
}

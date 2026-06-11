// SPDX-License-Identifier: Apache-2.0

import Foundation

enum PromptBuilder {
    // MARK: - System prompt (stable contract + optional agent appendix)

    static func systemPrompt(agentAppendix: String? = nil) -> String {
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
        webLookup: WebLookupSnapshot? = nil
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

        sections.append("## Task\nRespond to the screenshot above.")
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
        switch capture.ground {
        case .camera:
            lines.append("Ground: camera — the attached image is a photo from the Mac's camera (paper, whiteboard, book, or a physical object), not a screenshot of the display.")
        case .file:
            lines.append("Ground: imported file — the attached image is a page or image from a file the user opened from disk (e.g. a PDF page or a saved image), not a live capture of the current screen.")
        default:
            break
        }
        if capture.appName != nil || capture.windowTitle != nil {
            lines.append("Target: \(capture.targetLabel).")
        }
        if capture.hasVision {
            switch capture.ground {
            case .camera: lines.append("A camera photo is attached to this message (vision).")
            case .file:   lines.append("An image from the imported file is attached to this message (vision).")
            default:      lines.append("A screenshot is attached to this message (vision).")
            }
        }
        if let text = capture.text, !text.isEmpty {
            lines.append("""
            Supplementary extracted text (may be incomplete; prefer the screenshot when they disagree):
            ---
            \(text)
            ---
            """)
        } else {
            lines.append("No reliable extracted text — rely on the screenshot.")
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

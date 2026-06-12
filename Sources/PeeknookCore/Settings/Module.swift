// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A composable capability a profile can switch on. Completed at endgame shape; `parallelScreen` and
/// `agentActions` are reserved (not shipped). Modules are **not stored state** — see ``Module``.
public enum ModuleID: String, Codable, Sendable, CaseIterable, Hashable {
    case screenCapture
    case cameraCapture
    case parallelScreen
    case liveSession
    case voiceInput
    case speakAnswers
    case selectedText
    case webLookup
    case saveConversation
    case suggestFollowUps
    case agentActions
}

/// Modules are a **derived read-model**, not new storage. The existing flat opt-in booleans on
/// ``PeeknookSettings`` (and the active grounds on the profile) remain the single source of truth, so
/// nothing duplicates state and tolerant decoding is unchanged. A `Set<ModuleID>` on the profile
/// would instead decode "absent → empty → everything off", silently flipping every opt-in module off
/// on first load — strictly weaker. Per-profile *overrides* land with the profile editor; until then
/// every module answers from the global setting or the active ground.
public enum Module {
    public static func isEnabled(_ id: ModuleID, in settings: PeeknookSettings, profile: GroundProfile) -> Bool {
        // Per-profile forcing for the five opt-in modules only — `ModuleOverrides` filters at its
        // own boundaries too, so a corrupt blob can never decouple a grounded module from its
        // ground. Absent override = inherit the global setting (never "off").
        if let forced = profile.moduleOverrides.value(for: id) { return forced }
        switch id {
        case .webLookup:        return settings.webLookupEnabled
        case .voiceInput:       return settings.voiceInputEnabled
        case .speakAnswers:     return settings.speakAnswersEnabled
        case .saveConversation: return settings.persistConversation
        case .suggestFollowUps: return settings.suggestFollowUps
        case .selectedText:     return profile.activeGrounds.contains(.selectedText)
        case .screenCapture:    return profile.activeGrounds.contains(.screen)
        case .cameraCapture:    return profile.activeGrounds.contains(.camera)
        case .parallelScreen:   return settings.compositeCaptureEnabled   // composite (screen + camera)
        case .liveSession:      return settings.liveEnabled               // armed multi-turn live session
        case .agentActions:     return false                              // reserved, not shipped
        }
    }
}

// SPDX-License-Identifier: Apache-2.0

import Foundation

/// User-facing global capture shortcut persisted under `peeknook.settings.v1`.
/// Carbon masks match `cmdKey` (256), `shiftKey` (512), `optionKey` (2048), `controlKey` (4096).
public struct CaptureHotkey: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var carbonModifiers: UInt32
    public var keySymbol: String

    public init(keyCode: UInt32, carbonModifiers: UInt32, keySymbol: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.keySymbol = keySymbol
    }

    /// Default: ⌘⇧P — easier to read and say than ⌥⌘P.
    public static let `default` = CaptureHotkey(
        keyCode: 35,
        carbonModifiers: 256 | 512,
        keySymbol: "P"
    )

    public var modifierSymbols: [String] {
        var symbols: [String] = []
        if carbonModifiers & 4096 != 0 { symbols.append("⌃") }
        if carbonModifiers & 2048 != 0 { symbols.append("⌥") }
        if carbonModifiers & 512 != 0 { symbols.append("⇧") }
        if carbonModifiers & 256 != 0 { symbols.append("⌘") }
        return symbols
    }

    public var displaySymbols: [String] { modifierSymbols + [keySymbol] }

    public var display: String { displaySymbols.joined() }

    /// Spelled-out label for tooltips and accessibility.
    public var spokenLabel: String {
        var parts: [String] = []
        if carbonModifiers & 4096 != 0 { parts.append("Control") }
        if carbonModifiers & 2048 != 0 { parts.append("Option") }
        if carbonModifiers & 512 != 0 { parts.append("Shift") }
        if carbonModifiers & 256 != 0 { parts.append("Command") }
        parts.append(keySymbol)
        return parts.joined(separator: " + ")
    }
}

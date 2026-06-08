// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation
import Security

public enum ArchiveProtectionError: Error, Sendable, Equatable {
    case keyUnavailable
    case sealFailed
    case openFailed
}

/// Encrypts conversation thread payloads at the storage boundary (AES-GCM).
public protocol ConversationArchiveProtection: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ sealed: Data) throws -> Data

    /// Trusted, tamper-resistant record that the archive has been sealed at least once.
    /// `true` = sealed before; `false` = never sealed; `nil` = marker store unavailable
    /// (caller must fail soft — accept plaintext — to avoid data loss).
    func archiveHasBeenSealed() -> Bool?
    /// Best-effort: record that the archive is now encrypted. Tolerates failure.
    func markArchiveSealed()
}

/// Default marker behavior: no trusted store, so report "unknown" (nil) and do nothing. Conformers
/// without a tamper-resistant marker (tests, in-memory protections) stay fail-soft — nil means the
/// store accepts plaintext, preserving migration and never dropping History.
public extension ConversationArchiveProtection {
    func archiveHasBeenSealed() -> Bool? { nil }
    func markArchiveSealed() {}
}

public enum ArchiveEnvelope {
    public static let magic = Data("PKNKENC1".utf8)
    public static let version: UInt8 = 1

    public static func isEncrypted(_ data: Data) -> Bool {
        data.count > magic.count + 1 && data.prefix(magic.count) == magic
    }
}

struct AESGCMArchiveProtection: ConversationArchiveProtection {
    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    func seal(_ plaintext: Data) throws -> Data {
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw ArchiveProtectionError.sealFailed }
            var out = Data()
            out.append(ArchiveEnvelope.magic)
            out.append(ArchiveEnvelope.version)
            out.append(combined)
            return out
        } catch {
            throw ArchiveProtectionError.sealFailed
        }
    }

    func open(_ sealed: Data) throws -> Data {
        guard ArchiveEnvelope.isEncrypted(sealed) else { throw ArchiveProtectionError.openFailed }
        let payload = sealed.dropFirst(ArchiveEnvelope.magic.count + 1)
        do {
            let box = try AES.GCM.SealedBox(combined: Data(payload))
            return try AES.GCM.open(box, using: key)
        } catch {
            throw ArchiveProtectionError.openFailed
        }
    }
}

/// Production key stored in the Keychain (device-local, not synced).
public struct KeychainArchiveProtection: ConversationArchiveProtection {
    private static let service = "com.peeknook.app.archive"
    private static let account = "conversation-v1"
    /// Tamper-resistant "archive has been sealed at least once" marker. Keychain-backed so a
    /// local-file-write attacker cannot forge it; only the OS keychain (gated on device unlock) holds it.
    private static let sealedAccount = "archive-sealed-v1"

    private let inner: AESGCMArchiveProtection

    public init() throws {
        let key = try Self.loadOrCreateKey()
        self.inner = AESGCMArchiveProtection(key: key)
    }

    public func seal(_ plaintext: Data) throws -> Data {
        try inner.seal(plaintext)
    }

    public func open(_ sealed: Data) throws -> Data {
        try inner.open(sealed)
    }

    public func archiveHasBeenSealed() -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.sealedAccount,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: return nil // keychain unavailable / locked: caller fails soft (accepts plaintext)
        }
    }

    public func markArchiveSealed() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.sealedAccount,
            kSecValueData as String: Data([1]),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Best-effort: a duplicate just means it's already set, and any other failure must not block a save.
        _ = SecItemAdd(query as CFDictionary, nil)
    }

    private static func loadOrCreateKey() throws -> SymmetricKey {
        if let existing = try loadKey() { return existing }
        let key = SymmetricKey(size: .bits256)
        try storeKey(key)
        return key
    }

    private static func loadKey() throws -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ArchiveProtectionError.keyUnavailable
        }
        return SymmetricKey(data: data)
    }

    private static func storeKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ArchiveProtectionError.keyUnavailable }
    }
}

/// Fixed key for unit tests (no Keychain).
public struct FixedKeyArchiveProtection: ConversationArchiveProtection {
    private let inner: AESGCMArchiveProtection

    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) {
        self.inner = AESGCMArchiveProtection(key: key)
    }

    public func seal(_ plaintext: Data) throws -> Data { try inner.seal(plaintext) }
    public func open(_ sealed: Data) throws -> Data { try inner.open(sealed) }
}

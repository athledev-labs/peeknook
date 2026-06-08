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

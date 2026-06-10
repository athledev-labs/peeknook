// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

public enum CredentialStoreError: Error, Sendable, Equatable {
    case keychainUnavailable(OSStatus)
}

/// Stores one API key per ``CredentialRef``. Reads are non-throwing and fail soft: `nil` means
/// "no key OR store unreadable", and callers treat both as keyless (omit the Authorization
/// header) — a locked Keychain must degrade a request, never crash it. Writes throw so Settings
/// can tell the user a key didn't save.
public protocol CredentialStoring: Sendable {
    func apiKey(for ref: CredentialRef) -> String?
    /// Existence check that never returns key bytes (UI shows "key is set" without reading it).
    func hasKey(for ref: CredentialRef) -> Bool
    /// Empty or whitespace-only keys clear the slot (equivalent to `deleteAPIKey`).
    func setAPIKey(_ key: String?, for ref: CredentialRef) throws
    /// Idempotent: deleting an absent key succeeds.
    func deleteAPIKey(for ref: CredentialRef) throws
}

public extension CredentialStoring {
    func hasKey(for ref: CredentialRef) -> Bool { apiKey(for: ref) != nil }
}

/// Production store: generic-password items in the device-local Keychain (not synced), one item
/// per ref id. Mirrors `KeychainArchiveProtection` under a distinct service so inference
/// credentials and archive keys can never collide. `init` touches nothing — the Keychain is only
/// reached per call.
public struct KeychainCredentialStore: CredentialStoring {
    private static let service = "com.peeknook.app.inference-credentials"

    public init() {}

    public func apiKey(for ref: CredentialRef) -> String? {
        var query = Self.baseQuery(for: ref)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil // not found or Keychain unavailable: caller proceeds keyless
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func hasKey(for ref: CredentialRef) -> Bool {
        var query = Self.baseQuery(for: ref)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func setAPIKey(_ key: String?, for ref: CredentialRef) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            try deleteAPIKey(for: ref)
            return
        }
        let data = Data(trimmed.utf8)
        var update = Self.baseQuery(for: ref)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(update as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainUnavailable(updateStatus)
        }
        update[kSecValueData as String] = data
        update[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(update as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainUnavailable(addStatus)
        }
    }

    public func deleteAPIKey(for ref: CredentialRef) throws {
        let status = SecItemDelete(Self.baseQuery(for: ref) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainUnavailable(status)
        }
    }

    private static func baseQuery(for ref: CredentialRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref.id
        ]
    }
}

/// Unit-test / UI-test-host store (no Keychain). `failReads` simulates a locked Keychain:
/// reads degrade to keyless while writes keep succeeding.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [CredentialRef: String]
    private let failReads: Bool

    public init(seed: [CredentialRef: String] = [:], failReads: Bool = false) {
        self.keys = seed
        self.failReads = failReads
    }

    public func apiKey(for ref: CredentialRef) -> String? {
        guard !failReads else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return keys[ref]
    }

    public func hasKey(for ref: CredentialRef) -> Bool {
        guard !failReads else { return false }
        lock.lock()
        defer { lock.unlock() }
        return keys[ref] != nil
    }

    public func setAPIKey(_ key: String?, for ref: CredentialRef) throws {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        defer { lock.unlock() }
        if trimmed.isEmpty {
            keys[ref] = nil
        } else {
            keys[ref] = trimmed
        }
    }

    public func deleteAPIKey(for ref: CredentialRef) throws {
        lock.lock()
        defer { lock.unlock() }
        keys[ref] = nil
    }
}

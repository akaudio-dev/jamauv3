// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Andrei Kozlov

//
//  KeychainStore.swift
//  jamauv3Extension
//
//  Minimal Keychain wrapper for NINJAM server passwords. Passwords used to
//  live in plaintext UserDefaults (one copy per AU host container); the
//  Keychain keeps them encrypted at rest and out of backups/plists.
//

import Foundation
import Security

enum KeychainStore {
    private static let service = "com.jamauv3.ninjam-passwords"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Store (or overwrite) a password. An empty password deletes the entry.
    static func setPassword(_ password: String, account: String) {
        guard !password.isEmpty else {
            deletePassword(account: account)
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock as String,
        ]
        var addQuery = baseQuery(account: account)
        addQuery.merge(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        }
    }

    static func password(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}

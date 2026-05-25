//
//  Storage.swift
//  Lightweight UserDefaults + Keychain wrapper. No external deps.
//

import Foundation
import Security

enum Storage {

    enum Keys {
        static let publicKey   = "in.quickauth.sdk.publicKey"
        static let consent     = "in.quickauth.sdk.consent"
        static let lastClickId = "in.quickauth.sdk.lastClickId"
        static let installId   = "in.quickauth.sdk.installId"
        /// Persistent device token for OneTap (silent re-auth). Server-minted
        /// on the first /initiate, replayed on every subsequent call.
        static let deviceToken = "in.quickauth.sdk.deviceToken"
    }

    private static let suiteName = "in.quickauth.sdk"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - UserDefaults

    static func defaultsSet(value: Any?, key: String) {
        defaults.set(value, forKey: key)
    }

    static func defaultsGet(key: String) -> Any? {
        defaults.object(forKey: key)
    }

    static func defaultsRemove(key: String) {
        defaults.removeObject(forKey: key)
    }

    // MARK: - Keychain

    @discardableResult
    static func keychainSet(value: String, key: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func keychainGet(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let s = String(data: data, encoding: .utf8) else {
            return nil
        }
        return s
    }

    @discardableResult
    static func keychainDelete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Install ID

    /// A stable per-install identifier (UUID, persisted to UserDefaults).
    static func installID() -> String {
        if let s = defaultsGet(key: Keys.installId) as? String { return s }
        let id = UUID().uuidString
        defaultsSet(value: id, key: Keys.installId)
        return id
    }
}

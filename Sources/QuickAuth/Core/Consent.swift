//
//  Consent.swift
//  DPDP / GDPR user consent gate. Defaults to `false`.
//

import Foundation

public final class Consent {

    private let lock = NSLock()
    private var cached: Bool

    public init() {
        // Read from UserDefaults to survive launches.
        if let value = Storage.defaultsGet(key: Storage.Keys.consent) as? Bool {
            self.cached = value
        } else {
            self.cached = false
        }
    }

    /// Set consent and persist to UserDefaults.
    public func set(_ granted: Bool) {
        lock.lock(); defer { lock.unlock() }
        cached = granted
        Storage.defaultsSet(value: granted, key: Storage.Keys.consent)
    }

    /// Get current consent value.
    public func get() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cached
    }
}

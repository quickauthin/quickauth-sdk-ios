//
//  QuickAuth.swift
//  Public namespace facade for the QuickAuth iOS SDK.
//

import Foundation

/// Top-level facade. Use `QuickAuth.shared` after calling
/// `initialize(onTokenExpiry:)` (or `initialize(config:)`).
public final class QuickAuth {

    /// Shared singleton. Call `initialize` once on app launch.
    public static let shared = QuickAuth()

    /// Active SDK configuration. Mutated by `initialize`.
    public private(set) var config: Config = QuickAuth.placeholderConfig()

    /// User consent (DPDP / GDPR). Defaults to `false` until set.
    public let consent: Consent = Consent()

    /// Phone OTP + WhatsApp login service.
    public lazy var auth: OTPService = OTPService(api: apiClient, config: { [weak self] in self?.config ?? QuickAuth.placeholderConfig() })

    /// Marketing attribution + conversion tracking.
    public lazy var attribution: AttributionService = AttributionService(
        api: apiClient,
        consent: consent,
        config: { [weak self] in self?.config ?? QuickAuth.placeholderConfig() }
    )

    /// Underlying URLSession-based API client.
    public lazy var apiClient: APIClient = APIClient(config: { [weak self] in self?.config ?? QuickAuth.placeholderConfig() })

    private var initialized = false
    private let initLock = NSLock()

    private init() {}

    // MARK: - Initialization

    /// Initialize the SDK with a full `Config`.
    /// Idempotent — additional calls overwrite config and invalidate any
    /// cached session token.
    public func initialize(config: Config) {
        initLock.lock()
        defer { initLock.unlock() }

        self.config = config

        // Drop any token cached against the previous config.
        Task { [apiClient] in
            await apiClient.tokenManager.invalidate()
        }

        if config.unsafeDirectClientId != nil, config.unsafeDirectClientSecret != nil {
            print("[QuickAuth] ⚠️ UNSAFE mode: client_secret embedded; for trusted-enterprise only")
        }

        #if DEBUG
        OneTimeCode.warnIfAssociatedDomainsMissing()
        #endif

        initialized = true
    }

    /// Convenience initializer. Pass a closure that fetches a fresh
    /// 10-minute `sessionToken` from your backend (which in turn calls
    /// `POST /v1/sdk/session` with your `client_secret`).
    public func initialize(onTokenExpiry: @escaping TokenProvider) {
        initialize(config: Config(onTokenExpiry: onTokenExpiry))
    }

    /// Register / replace the headless auth event handler at runtime.
    /// Pre-built components (`QuickAuthLoginButton`, `QuickAuthLoginButtonView`)
    /// use this to install a transient handler for the duration of their
    /// flow, then restore the previous one. Apps that want a single global
    /// handler should pass it via `Config.onAuthEvent` at `initialize`.
    public func setAuthEventHandler(_ handler: AuthEventHandler?) {
        initLock.lock(); defer { initLock.unlock() }
        config.onAuthEvent = handler
    }

    /// Current auth event handler, if any.
    public var authEventHandler: AuthEventHandler? {
        config.onAuthEvent
    }

    /// Reset the SDK (test-only convenience). Clears Keychain & UserDefaults state.
    public func reset() {
        Storage.keychainDelete(key: Storage.Keys.publicKey)
        Storage.keychainDelete(key: Storage.Keys.deviceToken)
        Storage.defaultsRemove(key: Storage.Keys.consent)
        Storage.defaultsRemove(key: Storage.Keys.lastClickId)
        Task { [apiClient] in
            await apiClient.tokenManager.invalidate()
        }
        auth.reset(forgetDevice: true)
        config = QuickAuth.placeholderConfig()
        initialized = false
    }

    // MARK: - Internals

    /// Pre-init placeholder config whose `onTokenExpiry` always throws.
    /// Any API call before `initialize(...)` will surface as `.notInitialized`
    /// once the TokenManager fails to fetch a token.
    private static func placeholderConfig() -> Config {
        Config(onTokenExpiry: { throw QuickAuthError.notInitialized })
    }
}

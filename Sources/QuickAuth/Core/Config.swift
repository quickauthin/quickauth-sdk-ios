//
//  Config.swift
//

import Foundation

/// Closure type used by the SDK to fetch a fresh, short-lived `sessionToken`
/// from the customer's backend. Mirrors the web SDK's `onTokenExpiry`.
///
/// The customer's backend is expected to mint the token by calling
/// `POST /v1/sdk/session` server-to-server with their `client_id` /
/// `client_secret`, and return the resulting JWT to the app.
public typealias TokenProvider = () async throws -> String

/// SDK runtime configuration.
///
/// The SDK no longer accepts a long-lived `publicKey`. Instead it asks the
/// customer's backend (via `onTokenExpiry`) for a 10-minute `sessionToken`
/// which is sent as `Authorization: Bearer <token>` on every API call.
/// This matches the Twilio Verify pattern used by the web SDK.
public struct Config {

    public static let currentSDKVersion = "0.2.0"

    // MARK: Stored properties

    public var apiBaseURL: URL

    /// Async closure that returns a fresh `sessionToken`. Called by the SDK
    /// the first time it needs a token and again ~30s before each token
    /// expires (parsed from the JWT `exp` claim).
    public var onTokenExpiry: TokenProvider

    /// Optional pre-warmed token. If provided and not expired, the SDK uses
    /// this instead of immediately calling `onTokenExpiry` on the first
    /// request.
    public var initialToken: String?

    // MARK: Unsafe escape hatch (trusted-enterprise only)

    /// If both `unsafeDirectClientId` and `unsafeDirectClientSecret` are set,
    /// the SDK will mint its own `sessionToken` by calling
    /// `POST /v1/sdk/session` directly with those credentials. This embeds
    /// the client secret in the app binary and is **strongly discouraged**
    /// outside of trusted-enterprise distribution.
    public var unsafeDirectClientId: String?
    public var unsafeDirectClientSecret: String?

    // MARK: Networking knobs

    /// SDK version, sent as `X-QuickAuth-SDK: ios-sdk/<version>`.
    public var sdkVersion: String = currentSDKVersion

    /// Default request timeout in seconds.
    public var requestTimeout: TimeInterval = 20

    /// Number of retry attempts for idempotent requests on 5xx / network errors.
    public var maxRetries: Int = 2

    // MARK: Inits

    /// Recommended init. Customer supplies an async token provider.
    public init(
        apiBaseURL: URL = URL(string: "https://api.quickauth.in")!,
        onTokenExpiry: @escaping TokenProvider,
        initialToken: String? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.onTokenExpiry = onTokenExpiry
        self.initialToken = initialToken
    }

    /// **Unsafe** alternate init for trusted-enterprise builds where the
    /// `client_secret` is embedded directly in the app binary. The SDK will
    /// call `POST /v1/sdk/session` itself; `onTokenExpiry` is left as a
    /// no-op shim.
    public init(
        apiBaseURL: URL = URL(string: "https://api.quickauth.in")!,
        unsafeDirectClientId: String,
        unsafeDirectClientSecret: String
    ) {
        self.apiBaseURL = apiBaseURL
        self.unsafeDirectClientId = unsafeDirectClientId
        self.unsafeDirectClientSecret = unsafeDirectClientSecret
        self.onTokenExpiry = {
            // Replaced at TokenManager construction time when unsafe creds
            // are set; this stub exists only so the struct stays Sendable
            // without an Optional closure.
            throw QuickAuthError.notInitialized
        }
    }
}

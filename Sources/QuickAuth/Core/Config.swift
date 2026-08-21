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
/// Two auth modes, exactly one of which must be supplied:
///
/// * **Publishable key** (`publishableKey`) — the zero-backend quick start.
///   A `pk_live_…` / `pk_test_…` key is sent as `X-QuickAuth-Key` on every
///   call. Unlike the client *secret* this credential is meant to ship inside
///   the app: the backend scopes it to OTP initiate/verify, rate-limits it,
///   and can lock it to a registered app identity (iOS bundle id).
/// * **Session token** (`onTokenExpiry`) — the extra-hardened mode. The
///   customer's backend mints a 10-minute `sessionToken`, which the SDK sends
///   as `Authorization: Bearer <token>`. This matches the Twilio Verify
///   pattern used by the web SDK.
///
/// The publishable key is not a return of the old long-lived `publicKey` this
/// file used to warn against. The objection to `publicKey` was never its
/// lifetime — it was that a single embedded string carried full account
/// authority. A publishable key is a narrower credential: OTP-scoped,
/// app-lockable, rate-limited, and revocable on its own.
public struct Config {

    public static let currentSDKVersion = "1.1.0"

    // MARK: Stored properties

    public var apiBaseURL: URL

    /// Async closure that returns a fresh `sessionToken`. Called by the SDK
    /// the first time it needs a token and again ~30s before each token
    /// expires (parsed from the JWT `exp` claim).
    ///
    /// Optional because publishable-key mode never fetches a session token.
    /// A `nil` provider outside publishable-key / unsafe-direct mode means the
    /// SDK was never initialized, and surfaces as `.notInitialized`.
    public var onTokenExpiry: TokenProvider?

    /// Publishable key (`pk_live_…` / `pk_test_…`) for the zero-backend auth
    /// mode. When set, requests carry `X-QuickAuth-Key` and the TokenManager
    /// is never consulted.
    public var publishableKey: String?

    /// Optional pre-warmed token. If provided and not expired, the SDK uses
    /// this instead of immediately calling `onTokenExpiry` on the first
    /// request.
    public var initialToken: String?

    /// Headless auth event handler. The SDK invokes this with a typed
    /// `AuthEvent` as the auth lifecycle progresses (OTP sent, verified,
    /// failed, error). One handler per `Config`; assign a new closure to
    /// replace.
    ///
    /// Events are delivered asynchronously on the main queue so SwiftUI /
    /// UIKit observers can update views directly without dispatch hops.
    public var onAuthEvent: AuthEventHandler?

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

    // MARK: Mode

    /// `true` when the SDK is running in publishable-key (zero-backend) mode.
    ///
    /// Empty-string keys count as absent so that a missing build-time
    /// substitution (`""` from a stripped xcconfig) fails the init check
    /// loudly rather than silently sending `X-QuickAuth-Key: ` and getting a
    /// confusing 401 at runtime.
    public var isPublishableKeyMode: Bool {
        guard let key = publishableKey else { return false }
        return !key.isEmpty
    }

    /// `true` when the unsafe-enterprise escape hatch is fully configured.
    public var isUnsafeDirect: Bool {
        guard let id = unsafeDirectClientId, let secret = unsafeDirectClientSecret else { return false }
        return !id.isEmpty && !secret.isEmpty
    }

    // MARK: Inits

    /// Recommended init. Customer supplies an async token provider.
    public init(
        apiBaseURL: URL = URL(string: "https://api.quickauth.in")!,
        onTokenExpiry: @escaping TokenProvider,
        initialToken: String? = nil,
        onAuthEvent: AuthEventHandler? = nil
    ) {
        self.apiBaseURL = apiBaseURL
        self.onTokenExpiry = onTokenExpiry
        self.initialToken = initialToken
        self.onAuthEvent = onAuthEvent
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
        // No provider: `TokenManager` checks the unsafe credentials before it
        // ever reaches `onTokenExpiry`, so the stub that used to sit here only
        // existed to satisfy a non-Optional property that is now Optional.
        self.onTokenExpiry = nil
    }

    /// Validating init covering both auth modes. Use this when the key is only
    /// known at runtime (read from an xcconfig, remote config, or a flag) and
    /// you want the "exactly one mode" rule enforced rather than assumed.
    ///
    /// - Throws: `QuickAuthError.invalidConfiguration` when neither mode or
    ///   both modes are supplied. Failing at init is deliberate: both mistakes
    ///   otherwise surface as an opaque 401 from the server, on a device, long
    ///   after the wrong call site has scrolled out of view.
    public init(
        apiBaseURL: URL = URL(string: "https://api.quickauth.in")!,
        publishableKey: String?,
        onTokenExpiry: TokenProvider? = nil,
        initialToken: String? = nil,
        onAuthEvent: AuthEventHandler? = nil
    ) throws {
        self.apiBaseURL = apiBaseURL
        self.publishableKey = publishableKey
        self.onTokenExpiry = onTokenExpiry
        self.initialToken = initialToken
        self.onAuthEvent = onAuthEvent

        if isPublishableKeyMode && onTokenExpiry != nil {
            throw QuickAuthError.invalidConfiguration(
                "Pass either publishableKey or onTokenExpiry — not both. "
                + "They are different auth modes and the SDK cannot pick for you."
            )
        }
        if !isPublishableKeyMode && onTokenExpiry == nil {
            throw QuickAuthError.invalidConfiguration(
                "QuickAuth requires an auth mode: pass publishableKey (recommended, "
                + "zero-backend) or onTokenExpiry (server-minted session tokens)."
            )
        }
    }
}

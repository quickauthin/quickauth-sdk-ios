//
//  APIClient.swift
//  URLSession-based JSON client with publishable-key or ephemeral
//  session-token auth, idempotency keys, retries, and DI for tests.
//

import Foundation

/// Errors thrown by the API client.
public enum QuickAuthError: Error, LocalizedError, Equatable {
    case notInitialized
    case consentRequired
    case invalidResponse
    case http(status: Int, message: String?)
    case network(String)
    case decoding(String)
    case tokenProviderFailed(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:           return "QuickAuth.shared.initialize(onTokenExpiry:) must be called first."
        case .consentRequired:          return "User consent required for this operation."
        case .invalidResponse:          return "Invalid server response."
        case .http(let s, let m):       return "HTTP \(s)\(m.map { ": \($0)" } ?? "")"
        case .network(let m):           return "Network error: \(m)"
        case .decoding(let m):          return "Decoding error: \(m)"
        case .tokenProviderFailed(let m): return "onTokenExpiry failed: \(m)"
        case .invalidConfiguration(let m): return "Invalid QuickAuth configuration: \(m)"
        }
    }
}

/// Minimal protocol for URLSession injection (used by tests).
public protocol HTTPSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPSession {}

// MARK: - TokenManager

/// Thread-safe holder for the ephemeral `sessionToken`.
///
/// Responsibilities:
/// * Cache the current token and its parsed `exp` (from the JWT body).
/// * Refresh ~30s before expiry by calling `Config.onTokenExpiry` (or by
///   minting one directly when running in unsafe-enterprise mode).
/// * Single-flight: concurrent callers awaiting `getToken()` share a single
///   in-flight refresh `Task`.
/// * Allow explicit invalidation (e.g. on a 401 response).
public actor TokenManager {

    /// Refresh this many seconds **before** the JWT expiry to absorb clock
    /// skew and in-flight latency.
    static let refreshLeewaySeconds: TimeInterval = 30

    private let configProvider: () -> Config
    private let session: HTTPSession
    private let now: () -> Date

    private var token: String?
    private var expiresAt: Date?
    private var inFlight: Task<String, Error>?

    public init(
        config: @escaping () -> Config,
        session: HTTPSession,
        now: @escaping () -> Date = Date.init
    ) {
        self.configProvider = config
        self.session = session
        self.now = now

        // Adopt any pre-warmed token from Config.initialToken. If the token
        // isn't a parseable JWT we still cache it; we just optimistically
        // assume ~9 minutes of life so the first request uses it instead of
        // immediately calling the provider.
        let cfg = config()
        if let initial = cfg.initialToken, !initial.isEmpty {
            self.token = initial
            self.expiresAt = Self.expiryDate(fromJWT: initial) ?? now().addingTimeInterval(540)
        }
    }

    /// Return a valid token, refreshing if missing/expiring. Single-flight
    /// across concurrent callers.
    public func getToken() async throws -> String {
        if let t = token, let exp = expiresAt,
           exp.timeIntervalSince(now()) > Self.refreshLeewaySeconds {
            return t
        }
        // Token missing or expiring — coalesce with any in-flight refresh.
        if let inFlight = inFlight {
            return try await inFlight.value
        }
        let task = Task<String, Error> { [configProvider, session, now] in
            try await Self.fetchFreshToken(
                config: configProvider(),
                session: session,
                now: now
            )
        }
        inFlight = task
        do {
            let fresh = try await task.value
            self.token = fresh
            self.expiresAt = Self.expiryDate(fromJWT: fresh) ?? now().addingTimeInterval(540) // fallback ~9min
            self.inFlight = nil
            return fresh
        } catch {
            self.inFlight = nil
            throw error
        }
    }

    /// Drop the cached token (e.g. after a 401). Next `getToken()` will
    /// trigger a refresh.
    public func invalidate() {
        self.token = nil
        self.expiresAt = nil
    }

    /// Test hook: peek at the cached token (nil if cleared).
    public func currentToken() -> String? { token }

    // MARK: Helpers

    private static func fetchFreshToken(
        config: Config,
        session: HTTPSession,
        now: () -> Date
    ) async throws -> String {
        // Unsafe enterprise mode — SDK mints its own token using embedded
        // client_id / client_secret.
        if let cid = config.unsafeDirectClientId,
           let secret = config.unsafeDirectClientSecret,
           !cid.isEmpty, !secret.isEmpty {
            return try await mintTokenDirectly(
                clientId: cid,
                clientSecret: secret,
                config: config,
                session: session
            )
        }

        // Publishable-key mode never lands here — APIClient skips the
        // TokenManager entirely — so a missing provider at this point means
        // the app called an API before initialize(), not that it chose the
        // keyed mode.
        guard let provider = config.onTokenExpiry else {
            throw QuickAuthError.notInitialized
        }

        do {
            let token = try await provider()
            if token.isEmpty {
                throw QuickAuthError.tokenProviderFailed("empty token")
            }
            return token
        } catch let err as QuickAuthError {
            throw err
        } catch {
            throw QuickAuthError.tokenProviderFailed(error.localizedDescription)
        }
    }

    private static func mintTokenDirectly(
        clientId: String,
        clientSecret: String,
        config: Config,
        session: HTTPSession
    ) async throws -> String {
        guard let url = URL(string: "/v1/sdk/session", relativeTo: config.apiBaseURL) else {
            throw QuickAuthError.invalidResponse
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.requestTimeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(clientId, forHTTPHeaderField: "X-Client-Id")
        req.setValue(clientSecret, forHTTPHeaderField: "X-Client-Secret")
        req.setValue("ios-sdk/\(config.sdkVersion)", forHTTPHeaderField: "X-QuickAuth-SDK")
        req.httpBody = "{}".data(using: .utf8)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuickAuthError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8)
            throw QuickAuthError.http(status: http.statusCode, message: msg)
        }
        struct SessionResp: Decodable { let sessionToken: String? ; let token: String? }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let parsed: SessionResp
        do {
            parsed = try dec.decode(SessionResp.self, from: data)
        } catch {
            throw QuickAuthError.decoding(error.localizedDescription)
        }
        if let t = parsed.sessionToken, !t.isEmpty { return t }
        if let t = parsed.token, !t.isEmpty { return t }
        throw QuickAuthError.tokenProviderFailed("session response missing sessionToken")
    }

    /// Parse the `exp` claim from a JWT (`header.payload.signature`).
    /// Returns `nil` for non-JWT strings.
    static func expiryDate(fromJWT jwt: String) -> Date? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let payload = String(segments[1])
        guard let data = base64URLDecode(payload) else { return nil }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = (json["exp"] as? NSNumber)?.doubleValue ?? (json["exp"] as? Double)
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private static func base64URLDecode(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        let pad = str.count % 4
        if pad > 0 { str.append(String(repeating: "=", count: 4 - pad)) }
        return Data(base64Encoded: str)
    }
}

// MARK: - APIClient

public final class APIClient {

    private let configProvider: () -> Config
    private let session: HTTPSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public let tokenManager: TokenManager

    public init(
        config: @escaping () -> Config,
        session: HTTPSession? = nil,
        tokenManager: TokenManager? = nil
    ) {
        self.configProvider = config

        let resolvedSession: HTTPSession
        if let session = session {
            resolvedSession = session
        } else {
            let sc = URLSessionConfiguration.default
            sc.timeoutIntervalForRequest = config().requestTimeout
            sc.waitsForConnectivity = false
            resolvedSession = URLSession(configuration: sc)
        }
        self.session = resolvedSession
        self.tokenManager = tokenManager ?? TokenManager(config: config, session: resolvedSession)

        // No key strategy. The backend binds camelCase — sessionId, deviceToken, deviceInfo —
        // and .convertToSnakeCase rewrote every one of them on the way out. sessionId is
        // @NotBlank on the verify DTO, so it arrived null and the request was rejected 400
        // before reaching any logic: verify could not succeed on iOS at all. deviceToken and
        // deviceInfo were dropped the same way, which is why OneTap never fired here either.
        //
        // The decoder below keeps .convertFromSnakeCase deliberately. It is a no-op on the
        // camelCase the backend actually returns, and removing it is a second change with no
        // benefit.
        self.encoder = JSONEncoder()

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = dec
    }

    /// POST a JSON body and decode the response.
    ///
    /// - Parameter requireAuth: when `true` (default) the request is
    ///   authenticated. In publishable-key mode that means `X-QuickAuth-Key`
    ///   (plus `X-QuickAuth-Bundle` when available); otherwise the SDK fetches
    ///   a `sessionToken` via the TokenManager and attaches it as a Bearer
    ///   header, and on HTTP 401 invalidates the token and retries once.
    public func post<Body: Encodable, Response: Decodable>(
        path: String,
        body: Body,
        idempotencyKey: String? = nil,
        requireAuth: Bool = true
    ) async throws -> Response {
        let cfg = configProvider()

        guard let url = URL(string: path, relativeTo: cfg.apiBaseURL) else {
            throw QuickAuthError.invalidResponse
        }

        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw QuickAuthError.decoding("encode: \(error.localizedDescription)")
        }

        let idemKey = idempotencyKey ?? UUID().uuidString

        func makeRequest(token: String?) -> URLRequest {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = cfg.requestTimeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            if cfg.isPublishableKeyMode {
                // The two modes are mutually exclusive on the wire, not merely
                // by preference: sending both credentials would let a stale
                // bearer token decide the request's identity and silently
                // outrank the key the caller actually configured.
                req.setValue(cfg.publishableKey, forHTTPHeaderField: "X-QuickAuth-Key")
                if let bundleId = Self.appBundleIdentifier() {
                    req.setValue(bundleId, forHTTPHeaderField: "X-QuickAuth-Bundle")
                }
            } else if let token = token {
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            req.setValue("ios-sdk/\(cfg.sdkVersion)", forHTTPHeaderField: "X-QuickAuth-SDK")
            req.setValue(idemKey, forHTTPHeaderField: "Idempotency-Key")
            req.httpBody = bodyData
            return req
        }

        var token: String? = nil
        // Not just an optimisation: in publishable-key mode there is no token
        // provider to call, so consulting the TokenManager would throw
        // .notInitialized before the request ever left the device.
        if requireAuth && !cfg.isPublishableKeyMode {
            token = try await tokenManager.getToken()
        }
        let request = makeRequest(token: token)

        do {
            return try await sendWithRetry(request: request, retriesLeft: cfg.maxRetries)
        } catch QuickAuthError.http(let status, _) where status == 401 && requireAuth && !cfg.isPublishableKeyMode {
            // Token may have been revoked server-side. Force-refresh and
            // retry exactly once. A 401 in publishable-key mode is terminal —
            // the key is a static credential, so replaying the identical
            // request would only spend another rate-limit slot.
            await tokenManager.invalidate()
            let fresh = try await tokenManager.getToken()
            let retried = makeRequest(token: fresh)
            return try await sendWithRetry(request: retried, retriesLeft: cfg.maxRetries)
        }
    }

    // MARK: App identity

    /// Test seam for `appBundleIdentifier()`. Under `swift test` the host
    /// bundle has no identifier at all, so the real value is useless as a
    /// fixture and both the present and missing paths need to be driveable.
    static var bundleIdentifierOverride: (() -> String?)?

    /// Best-effort capture of the host app's bundle identifier, sent as
    /// `X-QuickAuth-Bundle` so the backend can app-lock a publishable key.
    ///
    /// This must never throw or trap. `Bundle.main.bundleIdentifier` is nil in
    /// several legitimate hosts (unit-test runners, some command-line and
    /// app-extension contexts), and an auth SDK that crashes or fails the call
    /// because it could not name itself is worse than one that omits a header.
    ///
    /// The omission is not free, though: the backend's app-lock **fails
    /// closed**. Once app-lock is enabled for a key, a request with no bundle
    /// header cannot match any registered app and is rejected — and if the key
    /// is enabled with an empty app list, every request is rejected. So
    /// omitting the header is only safe while app-lock is off, which is why
    /// this stays best-effort rather than becoming a hard precondition: the
    /// day app-lock is switched on, the fix belongs in the customer's app
    /// registration, not in a client-side crash.
    static func appBundleIdentifier() -> String? {
        // The seam swaps the *source* only; the emptiness check below stays on
        // the shared path so tests cannot pass through a validation the real
        // Bundle.main lookup is subject to.
        let raw = (bundleIdentifierOverride ?? { Bundle.main.bundleIdentifier })()
        guard let id = raw, !id.isEmpty else { return nil }
        return id
    }

    private func sendWithRetry<Response: Decodable>(request: URLRequest, retriesLeft: Int) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuickAuthError.invalidResponse
            }

            if (200..<300).contains(http.statusCode) {
                if Response.self == EmptyResponse.self {
                    return EmptyResponse() as! Response
                }
                do {
                    return try decoder.decode(Response.self, from: data)
                } catch {
                    throw QuickAuthError.decoding(error.localizedDescription)
                }
            }

            // Retry on 5xx
            if http.statusCode >= 500, retriesLeft > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return try await sendWithRetry(request: request, retriesLeft: retriesLeft - 1)
            }

            let message = String(data: data, encoding: .utf8)
            throw QuickAuthError.http(status: http.statusCode, message: message)
        } catch let err as QuickAuthError {
            throw err
        } catch {
            if retriesLeft > 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                return try await sendWithRetry(request: request, retriesLeft: retriesLeft - 1)
            }
            throw QuickAuthError.network(error.localizedDescription)
        }
    }
}

/// Used when callers don't care about a response body.
public struct EmptyResponse: Decodable { public init() {} }

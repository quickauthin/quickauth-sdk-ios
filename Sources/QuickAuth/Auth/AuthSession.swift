//
//  AuthSession.swift
//  Headless auth state machine. Single-callback event flow that
//  mirrors the web SDK.
//

import Foundation

/// State machine for the OTP / OneTap auth lifecycle.
///
/// Public API:
/// ```
/// try await QuickAuth.shared.auth.initiate(phone: "+919876543210")
/// try await QuickAuth.shared.auth.submitOtp("123456")
/// QuickAuth.shared.auth.reset(forgetDevice: true)
/// ```
///
/// All outcomes are delivered via `Config.onAuthEvent`. The async methods
/// throw only when the request couldn't be dispatched (validation error,
/// transport failure). Successful round-trips always resolve `Void`, and
/// the merchant relies on the event stream.
///
/// State diagram:
/// ```
///   idle ──initiate()──► sending ──OTP_SENT───► awaiting_otp ──submitOtp()──► verifying
///                              └──VERIFIED────► verified                              │
///                              └──error───────► failed                                │
///   verifying ──VERIFIED────► verified                                                │
///   verifying ──OTP_FAILED──► awaiting_otp ◄────────────────────────────────────────┘
///   any state ──reset()─────► idle
/// ```
public final class AuthSession {

    // MARK: - Wire DTOs (internal)

    enum BackendState: String, Decodable {
        case otpSent = "OTP_SENT"
        case verified = "VERIFIED"
        case otpFailed = "OTP_FAILED"
    }

    struct InitiateRequest: Encodable {
        let phone: String
        let channel: String
        let deviceToken: String?
        let deviceInfo: AnyEncodableDeviceInfo?
    }

    struct VerifyRequest: Encodable {
        let sessionId: String
        let code: String
        let deviceToken: String?
        let deviceInfo: AnyEncodableDeviceInfo?
    }

    struct InitiateResponse: Decodable {
        let state: BackendState?
        let sessionId: String
        let expiresIn: Int
        let deviceToken: String?
    }

    struct VerifyResponse: Decodable {
        let state: BackendState?
        let verified: Bool
        let requestId: String
        let message: String
    }

    // MARK: - State machine

    private enum State {
        case idle
        case sending(attemptId: Int)
        case awaitingOtp(attemptId: Int, sessionId: String)
        case verifying(attemptId: Int, sessionId: String)
        case verified(attemptId: Int, requestId: String)
        case failed(attemptId: Int)

        var attemptId: Int? {
            switch self {
            case .idle: return nil
            case .sending(let id), .awaitingOtp(let id, _),
                 .verifying(let id, _), .verified(let id, _), .failed(let id):
                return id
            }
        }
    }

    private let api: APIClient
    private let configProvider: () -> Config
    private let stateLock = NSLock()
    private var state: State = .idle
    private var attemptCounter: Int = 0

    init(api: APIClient, config: @escaping () -> Config) {
        self.api = api
        self.configProvider = config
    }

    // MARK: - Public API

    /// Begin an auth attempt. The SDK emits `.otpSent` (OTP delivery
    /// succeeded; show input) or `.verified` (OneTap fired; user already in)
    /// via `onAuthEvent`. Throws only on validation / transport failure.
    public func initiate(phone: String, channel: OTPChannel = .auto) async throws {
        guard Self.isE164(phone) else {
            throw QuickAuthError.invalidResponse
        }
        let attemptId = nextAttempt()
        setState(.sending(attemptId: attemptId))

        let body = InitiateRequest(
            phone: phone,
            channel: channel.rawValue,
            deviceToken: Storage.keychainGet(key: Storage.Keys.deviceToken),
            deviceInfo: makeDeviceInfo()
        )

        let res: InitiateResponse
        do {
            res = try await api.post(path: "/v1/sdk/auth/initiate", body: body)
        } catch {
            if currentAttempt() == attemptId {
                setState(.failed(attemptId: attemptId))
                emit(.error(code: Self.classify(error), message: Self.message(error)))
            }
            throw error
        }

        // Stale response — a newer initiate has taken over.
        guard currentAttempt() == attemptId else { return }

        if let token = res.deviceToken, !token.isEmpty {
            Storage.keychainSet(value: token, key: Storage.Keys.deviceToken)
        }

        if res.state == .verified {
            setState(.verified(attemptId: attemptId, requestId: res.sessionId))
            emit(.verified(requestId: res.sessionId, message: nil))
            return
        }

        setState(.awaitingOtp(attemptId: attemptId, sessionId: res.sessionId))
        emit(.otpSent(sessionId: res.sessionId, channel: channel, expiresIn: res.expiresIn))
    }

    /// Submit the user-entered OTP. Only valid in the `awaiting_otp` state.
    /// On success emits `.verified`; on wrong code emits `.otpFailed` and
    /// remains retry-able.
    public func submitOtp(_ code: String) async throws {
        guard Self.isOtpCode(code) else {
            throw QuickAuthError.invalidResponse
        }
        let (attemptId, sessionId) = try requireAwaitingOtp()
        setState(.verifying(attemptId: attemptId, sessionId: sessionId))

        let body = VerifyRequest(
            sessionId: sessionId,
            code: code,
            deviceToken: Storage.keychainGet(key: Storage.Keys.deviceToken),
            deviceInfo: makeDeviceInfo()
        )

        let res: VerifyResponse
        do {
            res = try await api.post(path: "/v1/sdk/auth/verify", body: body)
        } catch {
            if currentAttempt() == attemptId {
                setState(.failed(attemptId: attemptId))
                emit(.error(code: Self.classify(error), message: Self.message(error)))
            }
            throw error
        }

        guard currentAttempt() == attemptId else { return }

        if res.state == .verified || (res.state == nil && res.verified) {
            setState(.verified(attemptId: attemptId, requestId: res.requestId))
            emit(.verified(requestId: res.requestId, message: res.message))
            return
        }

        // OTP_FAILED — return to awaiting_otp so the user can retry.
        setState(.awaitingOtp(attemptId: attemptId, sessionId: sessionId))
        emit(.otpFailed(message: res.message))
    }

    /// Reset the state machine to idle. Use `forgetDevice: true` on
    /// user-initiated sign-out to also drop the persistent device token —
    /// the next `initiate()` will then look like a brand-new install
    /// (no OneTap).
    public func reset(forgetDevice: Bool = false) {
        stateLock.lock()
        state = .idle
        attemptCounter += 1   // invalidate any in-flight attempt
        stateLock.unlock()
        if forgetDevice {
            Storage.keychainDelete(key: Storage.Keys.deviceToken)
        }
    }

    /// Manually publish an auto-read OTP code into the event stream.
    /// Useful when integrating with an APN handler or SMS observer.
    public func publishAutoReadCode(_ code: String) {
        emit(.otpAutoRead(code: code))
    }

    // MARK: - Internals

    private func nextAttempt() -> Int {
        stateLock.lock()
        attemptCounter += 1
        let id = attemptCounter
        stateLock.unlock()
        return id
    }

    private func currentAttempt() -> Int? {
        stateLock.lock(); defer { stateLock.unlock() }
        return state.attemptId
    }

    private func setState(_ new: State) {
        stateLock.lock(); state = new; stateLock.unlock()
    }

    private func requireAwaitingOtp() throws -> (Int, String) {
        stateLock.lock(); defer { stateLock.unlock() }
        if case .awaitingOtp(let id, let sid) = state {
            return (id, sid)
        }
        throw QuickAuthError.invalidResponse
    }

    private func emit(_ event: AuthEvent) {
        let handler = configProvider().onAuthEvent
        guard let handler = handler else { return }
        // Hop to main so SwiftUI/UIKit observers can update views directly.
        if Thread.isMainThread {
            handler(event)
        } else {
            DispatchQueue.main.async { handler(event) }
        }
    }

    private func makeDeviceInfo() -> AnyEncodableDeviceInfo? {
        // Mirror the web SDK behaviour: include device info only when
        // consent is granted. We capture the values the backend's V48
        // device_info column expects — purely audit/admin, never used in
        // the trust decision.
        guard QuickAuth.shared.consent.get() else { return nil }
        return AnyEncodableDeviceInfo(DeviceInfo.current(sdkVersion: configProvider().sdkVersion))
    }

    // MARK: - Static helpers

    private static let e164Regex: NSRegularExpression = {
        // ^\+[1-9]\d{6,14}$
        return try! NSRegularExpression(pattern: #"^\+[1-9]\d{6,14}$"#)
    }()

    private static let otpRegex: NSRegularExpression = {
        return try! NSRegularExpression(pattern: #"^\d{4,8}$"#)
    }()

    static func isE164(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return e164Regex.firstMatch(in: s, range: range) != nil
    }

    static func isOtpCode(_ s: String) -> Bool {
        let range = NSRange(location: 0, length: s.utf16.count)
        return otpRegex.firstMatch(in: s, range: range) != nil
    }

    static func classify(_ err: Error) -> String {
        if let qe = err as? QuickAuthError {
            switch qe {
            case .http(let status, _):
                if status == 429 { return "RATE_LIMITED" }
                if status >= 500 { return "SERVER_ERROR" }
                if status >= 400 { return "CLIENT_ERROR" }
                return "HTTP_ERROR"
            case .network: return "NETWORK_ERROR"
            case .decoding: return "DECODING_ERROR"
            case .tokenProviderFailed: return "TOKEN_PROVIDER_FAILED"
            case .notInitialized: return "NOT_INITIALIZED"
            case .consentRequired: return "CONSENT_REQUIRED"
            case .invalidResponse: return "INVALID_RESPONSE"
            }
        }
        return "UNKNOWN_ERROR"
    }

    static func message(_ err: Error) -> String {
        (err as? LocalizedError)?.errorDescription ?? err.localizedDescription
    }
}

/// Type-erased wrapper so we can encode the existing `DeviceInfo` struct
/// into the request bodies without coupling the wire types to it directly.
struct AnyEncodableDeviceInfo: Encodable {
    private let encode: (Encoder) throws -> Void
    init<T: Encodable>(_ wrapped: T) {
        self.encode = wrapped.encode
    }
    func encode(to encoder: Encoder) throws { try encode(encoder) }
}

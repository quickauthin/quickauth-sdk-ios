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

    // MARK: - Live attempt (all guarded by `stateLock`)

    /// The phone and options of the live attempt, so `resendOtp()` needs no
    /// arguments.
    ///
    /// A merchant should not have to hold the number themselves to resend to
    /// it — they already gave it to us, and asking for it again is an
    /// opportunity to pass a different one by accident, which would start a
    /// second transaction and leave the user holding two codes, only one of
    /// which works.
    private var activePhone: String?
    private var activeChannel: OTPChannel = .auto

    /// Whether the current attempt should verify an auto-read code by itself.
    /// Off unless the caller asked for it on `initiate`.
    private var autoSubmitEnabled = false

    /// One auto-submit per attempt. A code can reach us twice — an SMS copy
    /// and a WhatsApp copy of the same message, or a host app that both
    /// forwards its text field and forwards a push payload — and submitting
    /// the second would verify a code the server has already consumed,
    /// surfacing as a spurious failure *after* a success.
    private var autoSubmitLatchFired = false

    init(api: APIClient, config: @escaping () -> Config) {
        self.api = api
        self.configProvider = config
    }

    // MARK: - Public API

    /// Begin an auth attempt. The SDK emits `.otpSent` (OTP delivery
    /// succeeded; show input) or `.verified` (OneTap fired; user already in)
    /// via `onAuthEvent`. Throws only on validation / transport failure.
    ///
    /// - Parameters:
    ///   - phone: E.164 number, e.g. `+919876543210`.
    ///   - channel: delivery channel; `.auto` lets the backend choose.
    ///   - autoSubmit: when `true`, a code that reaches the SDK through
    ///     `publishAutoReadCode(_:)` is verified by the SDK itself — the
    ///     caller does not have to call `submitOtp`. Off by default, because
    ///     submitting on the user's behalf is a surprise if they did not ask
    ///     for it. Exactly one auto-submit happens per attempt (see
    ///     `autoSubmitLatchFired`).
    ///
    /// This call also **arms auto-read for the attempt**: the latch is reset
    /// and the auto-submit preference recorded here, so a caller who never
    /// touches `observeOTP()` still gets `.otpAutoRead` events and
    /// auto-submission. Nothing about auto-read requires a subscriber.
    public func initiate(
        phone: String,
        channel: OTPChannel = .auto,
        autoSubmit: Bool = false
    ) async throws {
        guard Self.isE164(phone) else {
            throw QuickAuthError.invalidArgument(
                "phone must be E.164 formatted (e.g. +919876543210), got \"\(phone)\""
            )
        }
        let attemptId = beginAttempt(phone: phone, channel: channel, autoSubmit: autoSubmit)

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
            throw QuickAuthError.invalidArgument("OTP code must be 4–8 digits, got \"\(code)\"")
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

    /// Send the code again, to the number the current attempt is already for.
    ///
    /// Within the merchant's expiry window the server returns the SAME code and
    /// pushes the expiry forward, so a user who missed the first message gets
    /// that message again rather than a second code to choose between. Past the
    /// window it issues a fresh one, which is what an expired code deserves.
    ///
    /// Takes no phone number deliberately. The merchant already gave us one,
    /// and asking again is an opportunity to pass a different number by
    /// accident — which would start a separate transaction and leave the user
    /// holding two codes, only one of which works.
    ///
    /// Carries the original attempt's channel and `initiate`'s `autoSubmit`
    /// setting, so a resend behaves like the request it repeats rather than
    /// silently reverting to defaults. Like any `initiate`, it supersedes the
    /// previous attempt and resets the one-shot auto-submit latch, so the
    /// resent code can auto-submit even though the first one already did.
    ///
    /// - Throws: `QuickAuthError.invalidState` when there is no attempt to
    ///   resend. That is a programming error rather than a runtime condition:
    ///   a resend button should only exist once a code has been sent.
    public func resendOtp() async throws {
        let (phone, channel, autoSubmit) = liveAttempt()
        guard let phone = phone else {
            throw QuickAuthError.invalidState("resendOtp: nothing to resend — call initiate() first.")
        }
        try await initiate(phone: phone, channel: channel, autoSubmit: autoSubmit)
    }

    /// Reset the state machine to idle. Use `forgetDevice: true` on
    /// user-initiated sign-out to also drop the persistent device token —
    /// the next `initiate()` will then look like a brand-new install
    /// (no OneTap).
    public func reset(forgetDevice: Bool = false) {
        stateLock.lock()
        state = .idle
        attemptCounter += 1   // invalidate any in-flight attempt
        // Nothing left to resend to: a reset ends the attempt, and resending
        // afterwards would message someone who is no longer mid-login. Auto-read
        // is disarmed for the same reason — a late code must not submit itself
        // into a flow the user has left.
        activePhone = nil
        autoSubmitEnabled = false
        autoSubmitLatchFired = false
        stateLock.unlock()
        if forgetDevice {
            Storage.keychainDelete(key: Storage.Keys.deviceToken)
        }
    }

    /// Feed a code the SDK could not read itself into the auth flow.
    ///
    /// iOS gives the SDK no way to observe an inbound SMS: auto-fill is done by
    /// the OS, which offers the code as a keyboard suggestion straight into a
    /// text field with `textContentType = .oneTimeCode`. The SDK is never told.
    /// This method is the bridge — the host app hands over what the OS filled
    /// in (`QuickAuthOtpField` / `QuickAuthOTPTextField` do it for you), and
    /// from there the code behaves exactly like an Android auto-read: it emits
    /// `.otpAutoRead`, and auto-submits when the attempt asked for it.
    ///
    /// Safe to call at any time. Codes that are not 4–8 digits are ignored
    /// rather than emitted, since a partially-typed field would otherwise
    /// announce every keystroke as an auto-read.
    public func publishAutoReadCode(_ code: String) {
        guard Self.isOtpCode(code) else { return }
        emit(.otpAutoRead(code: code))
        maybeAutoSubmit(code)
    }

    // MARK: - Internals

    /// Verify an auto-read code on the caller's behalf, at most once per
    /// attempt.
    ///
    /// The latch is claimed before the submit is dispatched, not after it
    /// resolves — two codes arriving together would otherwise both find the
    /// latch open, and the second would verify a code the server consumed on
    /// the first, turning a success into a visible failure.
    private func maybeAutoSubmit(_ code: String) {
        stateLock.lock()
        guard autoSubmitEnabled, !autoSubmitLatchFired else {
            stateLock.unlock()
            return
        }
        // Only while a code is actually outstanding. A code arriving before
        // `.otpSent` (or after `.verified`) has nothing to submit against, and
        // burning the latch on it would silently disable auto-submit for the
        // code the user is actually waiting on.
        guard case .awaitingOtp = state else {
            stateLock.unlock()
            return
        }
        autoSubmitLatchFired = true
        stateLock.unlock()

        // Detached, not `Task { }`: a plain Task inherits the actor of whoever
        // published the code, and the publisher is nearly always a text-field
        // callback on the main actor — which would put the verify round-trip
        // behind whatever else the main actor is doing, and stall it outright
        // if that is a blocking spin. Outcomes still reach the merchant:
        // submitOtp emits `.verified` / `.otpFailed` / `.error` before it
        // throws, and emit() hops back to main for UI observers.
        Task.detached { [weak self] in
            try? await self?.submitOtp(code)
        }
    }

    /// What the live attempt was started with. Synchronous on purpose: taking
    /// an NSLock across an await point is a Swift 6 error, and there is nothing
    /// here worth suspending for.
    private func liveAttempt() -> (phone: String?, channel: OTPChannel, autoSubmit: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (activePhone, activeChannel, autoSubmitEnabled)
    }

    /// Claim the next attempt id and record what the attempt is for, in one
    /// critical section. Split across two locks, a concurrent `resendOtp`
    /// could read the previous attempt's phone after this one had already
    /// taken the id.
    private func beginAttempt(phone: String, channel: OTPChannel, autoSubmit: Bool) -> Int {
        stateLock.lock()
        attemptCounter += 1
        let id = attemptCounter
        state = .sending(attemptId: id)
        activePhone = phone
        activeChannel = channel
        autoSubmitEnabled = autoSubmit
        autoSubmitLatchFired = false
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
        throw QuickAuthError.invalidState(
            "submitOtp called before an OTP was sent — it must follow an .otpSent event."
        )
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
            case .invalidArgument: return "INVALID_ARGUMENT"
            case .invalidState: return "INVALID_STATE"
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

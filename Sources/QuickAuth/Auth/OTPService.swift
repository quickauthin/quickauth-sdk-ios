//
//  OTPService.swift
//  Lifecycle façade exposed at `QuickAuth.shared.auth`.
//
//  As of the headless-flow refactor, the core OTP / OneTap state machine
//  lives in `AuthSession`. This service composes it with the auxiliary
//  surface area that doesn't fit the state-machine model: an auto-read
//  publisher (Combine) for SMS observers and the WhatsApp deep-link
//  launcher.
//

import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Channel selection for OTP delivery.
public enum OTPChannel: String, Codable, Equatable {
    case sms
    case whatsapp
    /// Server picks the cheapest/fastest channel based on locale + customer config.
    case auto
}

public final class OTPService {

    /// Headless auth state machine — `initiate(phone:)`, `submitOtp(_:)`,
    /// `reset(forgetDevice:)`. All outcomes flow via `Config.onAuthEvent`.
    public let session: AuthSession

    /// Subject for code-observer integrations (e.g. SMS auto-read).
    private let codeSubject = PassthroughSubject<String, Never>()

    init(api: APIClient, config: @escaping () -> Config) {
        self.session = AuthSession(api: api, config: config)
    }

    // MARK: - Headless flow (forwards to AuthSession)

    /// Begin an auth attempt. Emits `.otpSent` (show OTP input) or
    /// `.verified` (OneTap fired, no input needed) via `onAuthEvent`.
    ///
    /// Pass `autoSubmit: true` to have the SDK verify an auto-read code
    /// itself; see `AuthSession.initiate(phone:channel:autoSubmit:)`.
    public func initiate(
        phone: String,
        channel: OTPChannel = .auto,
        autoSubmit: Bool = false
    ) async throws {
        try await session.initiate(phone: phone, channel: channel, autoSubmit: autoSubmit)
    }

    /// Send the code again, to the number the current attempt is already for.
    ///
    /// Takes no phone number deliberately: passing one again is an opportunity
    /// to pass a different one by accident, which would start a separate
    /// transaction and leave the user holding two codes, only one of which
    /// works. The original channel and `autoSubmit` setting are carried over.
    ///
    /// - Throws: `QuickAuthError.invalidState` when no attempt is live.
    public func resendOtp() async throws {
        try await session.resendOtp()
    }

    /// Submit the user-entered OTP. Only valid after an `.otpSent` event.
    public func submitOtp(_ code: String) async throws {
        try await session.submitOtp(code)
    }

    /// Reset the auth state machine. Pass `forgetDevice: true` on
    /// user-initiated sign-out to also drop the persistent device token.
    public func reset(forgetDevice: Bool = false) {
        session.reset(forgetDevice: forgetDevice)
    }

    // MARK: - Auto-read observer (Combine)

    /// Combine publisher of OTP codes that reached the SDK
    /// (used by `QuickAuthOtpField` / `QuickAuthOTPTextField` to auto-fill).
    ///
    /// Purely optional. Codes are delivered as `.otpAutoRead` on the event
    /// handler and auto-submitted (when the attempt asked for it) whether or
    /// not anyone subscribes here — subscribing is a convenience for callers
    /// who want a publisher rather than a switch over `AuthEvent`.
    public func observeOTP() -> AnyPublisher<String, Never> {
        codeSubject.eraseToAnyPublisher()
    }

    /// Feed a code the SDK could not read itself into the auth flow — the
    /// bridge from OS-level `oneTimeCode` autofill (or a push payload, or your
    /// own field) into the SDK.
    ///
    /// Surfaces on both the Combine publisher and the `onAuthEvent` stream,
    /// exactly once each, and auto-submits when the current attempt was
    /// started with `autoSubmit: true`.
    public func publishAutoReadCode(_ code: String) {
        // Screened once, here, so the publisher and the event stream never
        // disagree about what counted as a code.
        guard AuthSession.isOtpCode(code) else { return }
        codeSubject.send(code)
        session.publishAutoReadCode(code)
    }

    /// Former name of `publishAutoReadCode(_:)`, kept so 1.1.x call sites keep
    /// compiling.
    @available(*, deprecated, renamed: "publishAutoReadCode(_:)")
    public func publishObservedCode(_ code: String) {
        publishAutoReadCode(code)
    }

    // MARK: - WhatsApp login

    /// Launch WhatsApp via `wa.me/<number>?text=<encoded>`.
    /// On return, your app's Universal Link handler should hand the URL back to
    /// `QuickAuth.shared.attribution.captureLaunch(url:)`.
    /// - Returns: `true` if the URL was opened.
    @discardableResult
    public func startWhatsAppLogin(
        businessNumber: String,
        prefilledText: String = "Login",
        returnURL: URL? = nil
    ) -> Bool {
        whatsapp.open(
            businessNumber: businessNumber,
            prefilledText: prefilledText,
            returnURL: returnURL
        )
    }

    /// Stateless helper; the facade exposes its own instance at
    /// `QuickAuth.shared.whatsapp`.
    private let whatsapp = WhatsAppService()
}

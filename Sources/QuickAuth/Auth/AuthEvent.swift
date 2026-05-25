//
//  AuthEvent.swift
//  Public lifecycle events emitted by the headless auth session.
//

import Foundation

/// Typed lifecycle events the SDK pushes into the merchant's `onAuthEvent`
/// handler. Switch on the case to drive UI:
///
/// ```
/// switch event {
/// case .otpSent(let sessionId, let channel, let expiresIn):
///     showOtpInput()
/// case .otpAutoRead(let code):
///     prefillInput(code)
/// case .verified(let requestId, _):
///     finishLogin(with: requestId)
/// case .otpFailed(let message):
///     showError(message)
/// case .error(let code, let message):
///     showError(message)
/// }
/// ```
///
/// The SDK guarantees that any `initiate()` call produces at most one
/// terminal event (`verified` / `otpFailed` / `error`) for that attempt.
/// Calling `initiate()` again resets the state machine.
public enum AuthEvent: Equatable {
    /// Backend dispatched an OTP. Render the input.
    case otpSent(sessionId: String, channel: OTPChannel, expiresIn: Int)
    /// Inbound SMS was auto-read (e.g. via SMSReceiver/UNUserNotificationCenter
    /// observer). SDK does not auto-submit — the merchant decides whether to.
    case otpAutoRead(code: String)
    /// User is authenticated. Covers fresh OTP success AND silent
    /// device-trust re-auth. Forward `requestId` to the merchant backend.
    case verified(requestId: String, message: String?)
    /// Submitted code was rejected. SDK remains in awaiting-OTP state so the
    /// user can retry.
    case otpFailed(message: String)
    /// Transport / rate-limit / unexpected failure. Final for this attempt.
    case error(code: String, message: String)
}

/// One callback for the entire auth lifecycle. Pass at `Config` construction.
public typealias AuthEventHandler = (AuthEvent) -> Void

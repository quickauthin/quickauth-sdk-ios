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
    public func initiate(phone: String, channel: OTPChannel = .auto) async throws {
        try await session.initiate(phone: phone, channel: channel)
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

    /// Combine publisher of OTP codes observed by the SDK
    /// (used by `QuickAuthOtpField` / `QuickAuthOTPTextField` to auto-fill).
    /// Codes published here are also surfaced as `.otpAutoRead` events.
    public func observeOTP() -> AnyPublisher<String, Never> {
        codeSubject.eraseToAnyPublisher()
    }

    /// Manually publish a code into the observer stream. Surfaces to both
    /// the Combine publisher and the `onAuthEvent` stream.
    public func publishObservedCode(_ code: String) {
        codeSubject.send(code)
        session.publishAutoReadCode(code)
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
        let digits = businessNumber.filter { $0.isNumber }
        var components = URLComponents(string: "https://wa.me/\(digits)")
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "text", value: prefilledText)
        ]
        if let returnURL = returnURL {
            queryItems.append(URLQueryItem(name: "ref", value: returnURL.absoluteString))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return false }

        #if canImport(UIKit)
        guard Thread.isMainThread else {
            var ok = false
            DispatchQueue.main.sync {
                ok = UIApplication.shared.canOpenURL(url)
                if ok { UIApplication.shared.open(url, options: [:], completionHandler: nil) }
            }
            return ok
        }
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        return true
        #else
        return false
        #endif
    }
}

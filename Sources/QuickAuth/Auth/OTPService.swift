//
//  OTPService.swift
//  Phone OTP send/verify (SMS or WhatsApp) + WhatsApp login launcher.
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

/// Returned by `startOTP`.
public struct OTPSession: Decodable, Equatable {
    public let sessionId: String
    public let expiresIn: Int
    public let channel: String?
}

/// Returned by `verifyOTP`.
public struct OTPVerification: Decodable, Equatable {
    public let jwt: String
    public let expiresIn: Int
}

/// Internal request types.
struct StartOTPRequest: Encodable {
    let phone: String
    let channel: String
}

struct VerifyOTPRequest: Encodable {
    let sessionId: String
    let code: String
}

public final class OTPService {

    private let api: APIClient
    private let configProvider: () -> Config

    /// Subject to which an in-app OTP delivery (e.g. silent push observer or
    /// WhatsApp-login JWT extraction) can publish a code for `observeOTP`.
    private let codeSubject = PassthroughSubject<String, Never>()

    init(api: APIClient, config: @escaping () -> Config) {
        self.api = api
        self.configProvider = config
    }

    // MARK: - OTP

    /// Begin an OTP session. Returns `sessionId` to pass to `verifyOTP`.
    @discardableResult
    public func startOTP(phone: String, channel: OTPChannel = .auto) async throws -> OTPSession {
        let body = StartOTPRequest(phone: phone, channel: channel.rawValue)
        return try await api.post(path: "/v1/sdk/auth/initiate", body: body)
    }

    /// Verify the user-entered OTP code. Returns a JWT on success.
    @discardableResult
    public func verifyOTP(sessionId: String, code: String) async throws -> OTPVerification {
        let body = VerifyOTPRequest(sessionId: sessionId, code: code)
        return try await api.post(path: "/v1/sdk/auth/verify", body: body)
    }

    /// Combine publisher of OTP codes observed by the SDK
    /// (used by `QuickAuthOtpField` / `QuickAuthOTPTextField` to auto-fill).
    public func observeOTP() -> AnyPublisher<String, Never> {
        codeSubject.eraseToAnyPublisher()
    }

    /// Manually publish a code into the observer stream (e.g. from an APN handler).
    public func publishObservedCode(_ code: String) {
        codeSubject.send(code)
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

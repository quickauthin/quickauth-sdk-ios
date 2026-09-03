//
//  WhatsAppService.swift
//  Instance-shaped WhatsApp surface exposed at `QuickAuth.shared.whatsapp`.
//
//  The deep-link launcher used to live only inside `OTPService`, and the
//  return-URL parsers only on the `WhatsAppLogin` namespace, so "the WhatsApp
//  bit" had two unrelated entry points. This composes both without changing
//  either behaviour; `OTPService.startWhatsAppLogin` now delegates here.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public final class WhatsAppService {

    public init() {}

    /// Launch WhatsApp at `wa.me/<number>` with a prefilled message.
    ///
    /// - Parameter returnURL: your Universal Link; passed through as `ref` so
    ///   the conversation can send the user back to the app.
    /// - Returns: `true` if the URL was opened. Always `false` off UIKit
    ///   platforms, where there is nothing to open.
    @discardableResult
    public func open(
        businessNumber: String,
        prefilledText: String = "Login",
        returnURL: URL? = nil
    ) -> Bool {
        guard let url = Self.deepLink(
            businessNumber: businessNumber,
            prefilledText: prefilledText,
            returnURL: returnURL
        ) else { return false }

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

    /// True if the URL looks like a QuickAuth WhatsApp-login return URL.
    public func isReturnURL(_ url: URL) -> Bool { WhatsAppLogin.isReturnURL(url) }

    /// Parse `qa_clid`, `qa_session`, `qa_jwt` out of an inbound Universal Link.
    public func parseReturnURL(_ url: URL) -> [String: String] { WhatsAppLogin.parseReturnURL(url) }

    /// The `wa.me` URL that `open` would launch. Separated so it can be
    /// asserted on without a running UIApplication.
    static func deepLink(
        businessNumber: String,
        prefilledText: String,
        returnURL: URL?
    ) -> URL? {
        let digits = businessNumber.filter { $0.isNumber }
        var components = URLComponents(string: "https://wa.me/\(digits)")
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "text", value: prefilledText)]
        if let returnURL = returnURL {
            queryItems.append(URLQueryItem(name: "ref", value: returnURL.absoluteString))
        }
        components?.queryItems = queryItems
        return components?.url
    }
}

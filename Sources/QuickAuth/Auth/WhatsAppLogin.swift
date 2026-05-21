//
//  WhatsAppLogin.swift
//  Universal Link return-URL parsing helpers.
//

import Foundation

public enum WhatsAppLogin {

    /// Parse `qa_clid`, `qa_session`, `qa_jwt` from an inbound Universal Link.
    public static func parseReturnURL(_ url: URL) -> [String: String] {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            return [:]
        }
        var out: [String: String] = [:]
        for item in items {
            if let v = item.value { out[item.name] = v }
        }
        return out
    }

    /// True if the URL looks like a QuickAuth WhatsApp-login return URL.
    public static func isReturnURL(_ url: URL) -> Bool {
        let params = parseReturnURL(url)
        return params["qa_clid"] != nil || params["qa_session"] != nil || params["qa_jwt"] != nil
    }
}

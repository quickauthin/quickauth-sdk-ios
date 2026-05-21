//
//  OneTimeCode.swift
//  Helpers for SMS auto-fill via UITextContentType.oneTimeCode + domain-bound mode.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public enum OneTimeCode {

    /// The `textContentType` value to attach to UITextField / TextField for system OTP autofill.
    public static let textContentType = "oneTimeCode"

    /// Returns true if the host app's Info.plist declares an Associated Domains entitlement
    /// that includes a `webcredentials:` entry — required for domain-bound SMS autofill
    /// (`@yourdomain.com #123456` format).
    public static func hasAssociatedDomainsEntitlement() -> Bool {
        // Apple does not expose entitlements at runtime; we approximate by checking
        // the app's embedded.mobileprovision is impractical in-SDK. Best-effort:
        // look for an "associated-domains" key in main bundle's entitlement plist
        // shipped via build settings — fall back to false.
        guard let path = Bundle.main.path(forResource: "Entitlements", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any],
              let domains = dict["com.apple.developer.associated-domains"] as? [String]
        else {
            return false
        }
        return domains.contains(where: { $0.hasPrefix("webcredentials:") })
    }

    /// In DEBUG builds, log a warning if domain-bound SMS autofill won't work.
    static func warnIfAssociatedDomainsMissing() {
        #if DEBUG
        if !hasAssociatedDomainsEntitlement() {
            print("[QuickAuth] WARNING: Associated Domains entitlement (webcredentials:<your-domain>) "
                + "not detected. Domain-bound SMS autofill (`@yourdomain.com #123456`) won't work. "
                + "Configure the entitlement and host an apple-app-site-association file at "
                + "https://<your-domain>/.well-known/apple-app-site-association.")
        }
        #endif
    }

    #if canImport(UIKit)
    /// Apply `oneTimeCode` content type to an existing UITextField.
    public static func apply(to field: UITextField) {
        if #available(iOS 12.0, *) {
            field.textContentType = .oneTimeCode
        }
        field.keyboardType = .numberPad
    }
    #endif
}

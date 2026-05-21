//
//  Fingerprint.swift
//  Privacy-respecting device fingerprint for deferred-deep-link match.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(AdSupport)
import AdSupport
#endif

#if canImport(AppTrackingTransparency)
import AppTrackingTransparency
#endif

public struct Fingerprint: Encodable, Equatable {
    public let timezone: String
    public let locale: String
    public let language: String
    public let region: String?
    public let screenWidth: Int
    public let screenHeight: Int
    public let scale: Double
    public let userAgent: String
    /// Only populated if ATT consent has been granted by the user.
    public let idfa: String?

    /// Build a fingerprint from current device state.
    /// Honors App Tracking Transparency: never includes IDFA unless `.authorized`.
    public static func current() -> Fingerprint {
        let tz = TimeZone.current.identifier
        let locale = Locale.current.identifier
        let language = Locale.preferredLanguages.first ?? locale
        let region: String?
        if #available(iOS 16, macOS 13, *) {
            region = Locale.current.region?.identifier
        } else {
            region = (Locale.current as NSLocale).object(forKey: .countryCode) as? String
        }

        var width = 0
        var height = 0
        var scale = 1.0
        #if canImport(UIKit)
        let bounds = UIScreen.main.bounds
        width = Int(bounds.width)
        height = Int(bounds.height)
        scale = Double(UIScreen.main.scale)
        #endif

        let ua = "QuickAuth/\(Config.currentSDKVersion) (iOS \(systemVersion()))"
        let idfa = readIDFAIfAuthorized()

        return Fingerprint(
            timezone: tz,
            locale: locale,
            language: language,
            region: region,
            screenWidth: width,
            screenHeight: height,
            scale: scale,
            userAgent: ua,
            idfa: idfa
        )
    }

    /// Test-friendly explicit constructor.
    public init(
        timezone: String,
        locale: String,
        language: String,
        region: String?,
        screenWidth: Int,
        screenHeight: Int,
        scale: Double,
        userAgent: String,
        idfa: String?
    ) {
        self.timezone = timezone
        self.locale = locale
        self.language = language
        self.region = region
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.scale = scale
        self.userAgent = userAgent
        self.idfa = idfa
    }

    private static func systemVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private static func readIDFAIfAuthorized() -> String? {
        #if canImport(AppTrackingTransparency) && canImport(AdSupport)
        if #available(iOS 14, *) {
            guard ATTrackingManager.trackingAuthorizationStatus == .authorized else { return nil }
            let id = ASIdentifierManager.shared().advertisingIdentifier.uuidString
            // All-zero IDFA means no permission / unavailable.
            if id == "00000000-0000-0000-0000-000000000000" { return nil }
            return id
        }
        #endif
        return nil
    }
}

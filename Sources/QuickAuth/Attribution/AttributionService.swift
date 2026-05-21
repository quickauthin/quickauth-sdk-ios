//
//  AttributionService.swift
//  Universal Link capture + deferred-deep-link match + conversion tracking.
//

import Foundation

/// Result of an attribution match.
public struct AttributionResult: Decodable, Equatable {
    public let matched: Bool
    public let campaignId: String?
    public let templateId: String?
    public let variantId: String?
}

struct AttributionLaunchRequest: Encodable {
    let qaClid: String?
    let fingerprint: Fingerprint
    let deviceInfo: DeviceInfo
}

struct ConversionRequest: Encodable {
    let event: String
    let value: Double
    let currency: String
    let qaClid: String?
    let metadata: [String: String]?
}

public final class AttributionService {

    private let api: APIClient
    private let consent: Consent
    private let configProvider: () -> Config

    init(api: APIClient, consent: Consent, config: @escaping () -> Config) {
        self.api = api
        self.consent = consent
        self.configProvider = config
    }

    /// Capture an inbound Universal Link / launch URL. If `qa_clid` is present,
    /// it's persisted for later attribution-linked conversions. Sends a fingerprint
    /// to the backend for deferred-deep-link match. Requires consent.
    @discardableResult
    public func captureLaunch(url: URL?) async throws -> AttributionResult {
        guard consent.get() else {
            throw QuickAuthError.consentRequired
        }

        let qaClid = url.flatMap(Self.extractClickId(from:))
        if let qaClid = qaClid {
            Storage.defaultsSet(value: qaClid, key: Storage.Keys.lastClickId)
        }

        let body = AttributionLaunchRequest(
            qaClid: qaClid,
            fingerprint: Fingerprint.current(),
            deviceInfo: DeviceInfo.current(sdkVersion: configProvider().sdkVersion)
        )
        return try await api.post(path: "/v1/sdk/attribution/launch", body: body)
    }

    /// Track a conversion event (e.g. "signup", "purchase"). Requires consent.
    public func trackConversion(
        event: String,
        value: Double = 0,
        currency: String = "INR",
        metadata: [String: String]? = nil
    ) async throws {
        guard consent.get() else {
            throw QuickAuthError.consentRequired
        }
        let qaClid = Storage.defaultsGet(key: Storage.Keys.lastClickId) as? String
        let body = ConversionRequest(
            event: event,
            value: value,
            currency: currency,
            qaClid: qaClid,
            metadata: metadata
        )
        let _: EmptyResponse = try await api.post(path: "/v1/sdk/attribution/conversion", body: body)
    }

    /// Returns the most recently captured `qa_clid`, if any.
    public var lastClickId: String? {
        Storage.defaultsGet(key: Storage.Keys.lastClickId) as? String
    }

    // MARK: - Helpers

    /// Extract `qa_clid` from a URL's query string. `internal` for tests.
    static func extractClickId(from url: URL) -> String? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = comps.queryItems else { return nil }
        return items.first(where: { $0.name == "qa_clid" })?.value
    }
}

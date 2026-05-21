//
//  ConsentTests.swift
//

import XCTest
@testable import QuickAuth

final class ConsentTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
    }

    override func tearDown() {
        Storage.defaultsRemove(key: Storage.Keys.consent)
        Storage.defaultsRemove(key: Storage.Keys.lastClickId)
        super.tearDown()
    }

    func testDefaultConsentIsFalse() {
        Storage.defaultsRemove(key: Storage.Keys.consent)
        let c = Consent()
        XCTAssertFalse(c.get())
    }

    func testSetGetConsent() {
        let c = Consent()
        c.set(true)
        XCTAssertTrue(c.get())
        c.set(false)
        XCTAssertFalse(c.get())
    }

    func testAttributionBlockedWhenConsentFalse() async {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test"
        )
        let api = APIClient(config: { cfg }, session: session)
        let consent = Consent()
        consent.set(false)
        let svc = AttributionService(api: api, consent: consent, config: { cfg })
        do {
            _ = try await svc.captureLaunch(url: URL(string: "https://example.com?qa_clid=xyz"))
            XCTFail("should have thrown")
        } catch QuickAuthError.consentRequired {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testConversionBlockedWhenConsentFalse() async {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test"
        )
        let api = APIClient(config: { cfg }, session: session)
        let consent = Consent()
        consent.set(false)
        let svc = AttributionService(api: api, consent: consent, config: { cfg })
        do {
            try await svc.trackConversion(event: "signup")
            XCTFail("should have thrown")
        } catch QuickAuthError.consentRequired {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testCaptureLaunchProceedsWhenConsentTrue() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/attribution/launch")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"matched\":true,\"campaign_id\":\"c1\"}".data(using: .utf8))
        }
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test"
        )
        let api = APIClient(config: { cfg }, session: session)
        let consent = Consent()
        consent.set(true)
        let svc = AttributionService(api: api, consent: consent, config: { cfg })
        let url = URL(string: "https://app.example.com/open?qa_clid=clk_42")!
        let result = try await svc.captureLaunch(url: url)
        XCTAssertTrue(result.matched)
        XCTAssertEqual(result.campaignId, "c1")
        XCTAssertEqual(svc.lastClickId, "clk_42")
    }
}

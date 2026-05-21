//
//  OTPServiceTests.swift
//

import XCTest
import Combine
@testable import QuickAuth

final class OTPServiceTests: XCTestCase {

    private var session: URLSession!
    private var cancellables: Set<AnyCancellable> = []

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
    }

    private func makeService() -> OTPService {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test"
        )
        let api = APIClient(config: { cfg }, session: session)
        return OTPService(api: api, config: { cfg })
    }

    func testStartOTPSendsCorrectBodyAndReturnsSession() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"session_id\":\"sess_1\",\"expires_in\":300,\"channel\":\"sms\"}".data(using: .utf8))
        }
        let svc = makeService()
        let result = try await svc.startOTP(phone: "+919876543210", channel: .sms)

        XCTAssertEqual(result.sessionId, "sess_1")
        XCTAssertEqual(result.expiresIn, 300)
        XCTAssertEqual(result.channel, "sms")

        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/v1/sdk/auth/initiate")
        let body = try XCTUnwrap(req.httpBody)
        let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(dict?["phone"] as? String, "+919876543210")
        XCTAssertEqual(dict?["channel"] as? String, "sms")
    }

    func testVerifyOTPParsesJWT() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/verify")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"jwt\":\"a.b.c\",\"expires_in\":3600}".data(using: .utf8))
        }
        let svc = makeService()
        let result = try await svc.verifyOTP(sessionId: "sess_1", code: "123456")
        XCTAssertEqual(result.jwt, "a.b.c")
        XCTAssertEqual(result.expiresIn, 3600)
    }

    func testObserveOTPReceivesPublishedCode() {
        let svc = makeService()
        let exp = expectation(description: "receive code")
        var received: String?
        svc.observeOTP().sink { code in
            received = code
            exp.fulfill()
        }.store(in: &cancellables)

        svc.publishObservedCode("987654")

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, "987654")
    }

    func testWhatsAppLoginExtractsClickId() {
        let url = URL(string: "https://app.example.com/return?qa_clid=clk_xyz&qa_session=s1")!
        XCTAssertTrue(WhatsAppLogin.isReturnURL(url))
        let params = WhatsAppLogin.parseReturnURL(url)
        XCTAssertEqual(params["qa_clid"], "clk_xyz")
        XCTAssertEqual(params["qa_session"], "s1")
    }

    func testAttributionExtractClickId() {
        let url = URL(string: "https://app.example.com/open?qa_clid=clk_42&utm=ig")!
        XCTAssertEqual(AttributionService.extractClickId(from: url), "clk_42")
        let bad = URL(string: "https://app.example.com/open")!
        XCTAssertNil(AttributionService.extractClickId(from: bad))
    }
}

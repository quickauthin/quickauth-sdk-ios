//
//  OTPServiceTests.swift
//

import XCTest
import Combine
@testable import QuickAuth

final class OTPServiceTests: XCTestCase {

    private var session: URLSession!
    private var cancellables: Set<AnyCancellable> = []
    private var capturedEvents: [AuthEvent] = []

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
        capturedEvents = []
        Storage.keychainDelete(key: Storage.Keys.deviceToken)
    }

    private func makeService(onAuthEvent: AuthEventHandler? = nil) -> OTPService {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test",
            onAuthEvent: onAuthEvent
        )
        QuickAuth.shared.initialize(config: cfg)
        let api = APIClient(config: { cfg }, session: session)
        return OTPService(api: api, config: { cfg })
    }

    /// Block the test until at least `count` events have been observed.
    /// Events are dispatched on the main queue, so we drain run loops.
    private func waitForEvents(count: Int, timeout: TimeInterval = 1.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while capturedEvents.count < count && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    func testInitiateSendsCorrectBodyAndEmitsOtpSent() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"state\":\"OTP_SENT\",\"session_id\":\"sess_1\",\"expires_in\":300,\"device_token\":\"dtok_x\"}".data(using: .utf8))
        }
        let svc = makeService(onAuthEvent: { [weak self] in self?.capturedEvents.append($0) })

        try await svc.initiate(phone: "+919876543210", channel: .sms)
        waitForEvents(count: 1)

        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.path, "/v1/sdk/auth/initiate")
        let body = try XCTUnwrap(req.httpBody)
        let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(dict?["phone"] as? String, "+919876543210")
        XCTAssertEqual(dict?["channel"] as? String, "sms")

        XCTAssertEqual(capturedEvents.count, 1)
        if case .otpSent(let sid, let ch, let exp) = capturedEvents[0] {
            XCTAssertEqual(sid, "sess_1")
            XCTAssertEqual(ch, .sms)
            XCTAssertEqual(exp, 300)
        } else {
            XCTFail("Expected .otpSent, got \(capturedEvents[0])")
        }

        XCTAssertEqual(Storage.keychainGet(key: Storage.Keys.deviceToken), "dtok_x")
    }

    func testInitiateEmitsVerifiedDirectlyWhenBackendReportsOneTap() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"state\":\"VERIFIED\",\"session_id\":\"req_verified\",\"expires_in\":300,\"device_token\":\"dtok_x\"}".data(using: .utf8))
        }
        let svc = makeService(onAuthEvent: { [weak self] in self?.capturedEvents.append($0) })

        try await svc.initiate(phone: "+919876543210", channel: .sms)
        waitForEvents(count: 1)

        XCTAssertEqual(capturedEvents.count, 1)
        if case .verified(let requestId, _) = capturedEvents[0] {
            XCTAssertEqual(requestId, "req_verified")
        } else {
            XCTFail("Expected .verified, got \(capturedEvents[0])")
        }
    }

    func testSubmitOtpEmitsVerifiedOnSuccess() async throws {
        var responseCount = 0
        MockURLProtocol.requestHandler = { _ in
            responseCount += 1
            if responseCount == 1 {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"state\":\"OTP_SENT\",\"session_id\":\"sess_1\",\"expires_in\":300,\"device_token\":\"dtok_v\"}".data(using: .utf8))
            }
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/verify")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"state\":\"VERIFIED\",\"verified\":true,\"request_id\":\"req_abc\",\"message\":\"Verified successfully\"}".data(using: .utf8))
        }
        let svc = makeService(onAuthEvent: { [weak self] in self?.capturedEvents.append($0) })

        try await svc.initiate(phone: "+919876543210")
        try await svc.submitOtp("123456")
        waitForEvents(count: 2)

        XCTAssertEqual(capturedEvents.count, 2)
        XCTAssertEqual(events: capturedEvents, expectedTypes: ["otpSent", "verified"])

        // Verify deviceToken was replayed on the verify call.
        let verifyReq = MockURLProtocol.capturedRequests[1]
        let body = try XCTUnwrap(verifyReq.httpBody)
        let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(dict?["session_id"] as? String, "sess_1")
        XCTAssertEqual(dict?["code"] as? String, "123456")
        XCTAssertEqual(dict?["device_token"] as? String, "dtok_v")
    }

    func testSubmitOtpEmitsOtpFailedOnWrongCode() async throws {
        var responseCount = 0
        MockURLProtocol.requestHandler = { _ in
            responseCount += 1
            if responseCount == 1 {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"state\":\"OTP_SENT\",\"session_id\":\"sess_1\",\"expires_in\":300,\"device_token\":\"dtok_v\"}".data(using: .utf8))
            }
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/verify")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"state\":\"OTP_FAILED\",\"verified\":false,\"request_id\":\"sess_1\",\"message\":\"Invalid OTP. 2 attempt(s) remaining.\"}".data(using: .utf8))
        }
        let svc = makeService(onAuthEvent: { [weak self] in self?.capturedEvents.append($0) })

        try await svc.initiate(phone: "+919876543210")
        try await svc.submitOtp("000000")
        waitForEvents(count: 2)

        XCTAssertEqual(events: capturedEvents, expectedTypes: ["otpSent", "otpFailed"])
    }

    func testSubmitOtpBeforeInitiateThrows() async throws {
        let svc = makeService()
        do {
            try await svc.submitOtp("123456")
            XCTFail("Expected throw")
        } catch {
            // expected
        }
    }

    func testResetWithForgetDeviceClearsKeychain() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"state\":\"OTP_SENT\",\"session_id\":\"sess_1\",\"expires_in\":300,\"device_token\":\"dtok_keep\"}".data(using: .utf8))
        }
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210")
        XCTAssertEqual(Storage.keychainGet(key: Storage.Keys.deviceToken), "dtok_keep")

        svc.reset(forgetDevice: true)
        XCTAssertNil(Storage.keychainGet(key: Storage.Keys.deviceToken))
    }

    func testObserveOTPReceivesPublishedCode() {
        let svc = makeService(onAuthEvent: { [weak self] in self?.capturedEvents.append($0) })
        let exp = expectation(description: "receive code")
        var received: String?
        svc.observeOTP().sink { code in
            received = code
            exp.fulfill()
        }.store(in: &cancellables)

        svc.publishObservedCode("987654")

        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(received, "987654")
        waitForEvents(count: 1)
        XCTAssertEqual(events: capturedEvents, expectedTypes: ["otpAutoRead"])
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

// MARK: - Event assertion helper

private func XCTAssertEqual(
    events: [AuthEvent],
    expectedTypes: [String],
    file: StaticString = #file,
    line: UInt = #line
) {
    let actual = events.map { eventTypeName($0) }
    XCTAssertEqual(actual, expectedTypes, file: file, line: line)
}

private func eventTypeName(_ e: AuthEvent) -> String {
    switch e {
    case .otpSent: return "otpSent"
    case .otpAutoRead: return "otpAutoRead"
    case .verified: return "verified"
    case .otpFailed: return "otpFailed"
    case .error: return "error"
    }
}

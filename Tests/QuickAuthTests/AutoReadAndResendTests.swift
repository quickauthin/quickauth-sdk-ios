//
//  AutoReadAndResendTests.swift
//  Parity coverage for resendOtp(), the autoSubmit one-shot latch, and the
//  auto-read path being armed by initiate() rather than by a subscriber.
//

import XCTest
import Combine
@testable import QuickAuth

/// `@MainActor` is load-bearing, not decoration. Events are delivered with
/// `DispatchQueue.main.async`, so a test body running on a cooperative thread
/// would be reading `capturedEvents` while the main queue appends to it — a
/// data race on a Swift Array that surfaces as an intermittent SIGSEGV rather
/// than a failure. Pinned to the main actor, the appends can only land while
/// this test is parked in `waitForEvents`.
@MainActor
final class AutoReadAndResendTests: XCTestCase {

    private var session: URLSession!
    private var cancellables: Set<AnyCancellable> = []
    private var capturedEvents: [AuthEvent] = []

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
        capturedEvents = []
        cancellables = []
        Storage.keychainDelete(key: Storage.Keys.deviceToken)
    }

    override func tearDown() async throws {
        // Auto-submit runs work this test never awaited. Let it land before the
        // next test resets the mock underneath it.
        await settle(0.1)
        MockURLProtocol.reset()
        cancellables = []
        try await super.tearDown()
    }

    // MARK: - Fixtures

    private func makeService() -> OTPService {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: { "qa_session_test" },
            initialToken: "qa_session_test",
            onAuthEvent: { [weak self] in self?.capturedEvents.append($0) }
        )
        QuickAuth.shared.initialize(config: cfg)
        let api = APIClient(config: { cfg }, session: session)
        return OTPService(api: api, config: { cfg })
    }

    /// Answer every `/initiate` with OTP_SENT and every `/verify` with the
    /// given state, so a test can drive several attempts without counting.
    private func routeByPath(verifyState: String = "VERIFIED") {
        MockURLProtocol.requestHandler = { req in
            let path = req.url?.path ?? ""
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if path.hasSuffix("/verify") {
                let verified = verifyState == "VERIFIED"
                let body = """
                {"state":"\(verifyState)","verified":\(verified),"request_id":"req_abc","message":"Verified successfully"}
                """
                return (response, body.data(using: .utf8))
            }
            let body = """
            {"state":"OTP_SENT","session_id":"sess_1","expires_in":300,"device_token":"dtok_x"}
            """
            return (response, body.data(using: .utf8))
        }
    }

    /// Events are delivered on the main queue and auto-submit runs on a
    /// detached Task, so wait by *suspending* rather than by spinning a run
    /// loop: a blocking spin holds the main actor, and anything queued on it
    /// (including the event handler) then cannot run until we give it up.
    private func waitForEvents(count: Int, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while capturedEvents.count < count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Give work that should NOT happen a fair chance to happen.
    private func settle(_ seconds: TimeInterval = 0.3) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func requestPaths() -> [String] {
        MockURLProtocol.capturedRequests.compactMap { $0.url?.path }
    }

    private func body(of index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(MockURLProtocol.capturedRequests[index].httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - resendOtp

    func testResendWithNoActiveAttemptThrowsInvalidState() async {
        let svc = makeService()
        do {
            try await svc.resendOtp()
            XCTFail("Expected resendOtp to throw with no attempt in flight")
        } catch let error as QuickAuthError {
            guard case .invalidState = error else {
                return XCTFail("Expected .invalidState, got \(error)")
            }
        } catch {
            XCTFail("Expected QuickAuthError, got \(error)")
        }
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty, "A failed resend must not hit the network")
    }

    func testResendReplaysThePhoneAndChannelOfTheCurrentAttempt() async throws {
        routeByPath()
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210", channel: .whatsapp)
        try await svc.resendOtp()
        await waitForEvents(count: 2)

        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate", "/v1/sdk/auth/initiate"])
        let resent = try body(of: 1)
        XCTAssertEqual(resent["phone"] as? String, "+919876543210")
        XCTAssertEqual(resent["channel"] as? String, "whatsapp",
                       "A resend must keep the channel of the request it repeats")
    }

    func testResetClearsTheResendTarget() async throws {
        routeByPath()
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210")
        svc.reset()

        do {
            try await svc.resendOtp()
            XCTFail("Expected resendOtp to throw after reset")
        } catch let error as QuickAuthError {
            guard case .invalidState = error else {
                return XCTFail("Expected .invalidState, got \(error)")
            }
        }
    }

    // MARK: - autoSubmit

    func testAutoSubmitIsOffByDefault() async throws {
        routeByPath()
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210")
        await waitForEvents(count: 1)

        svc.publishAutoReadCode("123456")
        await waitForEvents(count: 2)
        await settle()

        XCTAssertEqual(capturedEvents.map(name), ["otpSent", "otpAutoRead"],
                       "Default must surface the code and stop there")
        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate"],
                       "Nothing may be verified unless the caller asked for autoSubmit")
    }

    func testAutoSubmitFiresWithoutAnyObserveOTPSubscriber() async throws {
        routeByPath()
        let svc = makeService()

        // Deliberately no observeOTP() subscription: initiate() arms auto-read
        // by itself, and a caller told they need not listen must still get this.
        try await svc.initiate(phone: "+919876543210", autoSubmit: true)
        await waitForEvents(count: 1)

        svc.publishAutoReadCode("123456")
        await waitForEvents(count: 3)

        XCTAssertEqual(capturedEvents.map(name), ["otpSent", "otpAutoRead", "verified"])
        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate", "/v1/sdk/auth/verify"])
        XCTAssertEqual(try body(of: 1)["code"] as? String, "123456")
    }

    func testAutoSubmitLatchAllowsOnlyOneSubmitPerAttempt() async throws {
        routeByPath()
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210", autoSubmit: true)
        await waitForEvents(count: 1)

        // The same code delivered twice — an SMS copy and a WhatsApp copy, or a
        // text field that fires twice. The second must not verify a code the
        // server has already consumed.
        svc.publishAutoReadCode("123456")
        svc.publishAutoReadCode("123456")
        await waitForEvents(count: 4)
        await settle()

        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate", "/v1/sdk/auth/verify"])
        XCTAssertEqual(capturedEvents.map(name), ["otpSent", "otpAutoRead", "otpAutoRead", "verified"],
                       "Both codes are still announced; only one is submitted")
    }

    func testResendCarriesAutoSubmitAndRearmsTheLatch() async throws {
        routeByPath(verifyState: "OTP_FAILED")
        let svc = makeService()

        try await svc.initiate(phone: "+919876543210", autoSubmit: true)
        await waitForEvents(count: 1)
        svc.publishAutoReadCode("111111")
        await waitForEvents(count: 3)   // otpSent, otpAutoRead, otpFailed

        try await svc.resendOtp()
        await waitForEvents(count: 4)
        svc.publishAutoReadCode("222222")
        await waitForEvents(count: 6)

        XCTAssertEqual(requestPaths(), [
            "/v1/sdk/auth/initiate",
            "/v1/sdk/auth/verify",
            "/v1/sdk/auth/initiate",
            "/v1/sdk/auth/verify"
        ], "The resent attempt gets its own auto-submit")
        XCTAssertEqual(try body(of: 3)["code"] as? String, "222222")
    }

    func testAutoSubmitIgnoresCodesArrivingBeforeAnOtpWasSent() async throws {
        routeByPath()
        let svc = makeService()

        // No attempt yet: nothing to submit against, and the latch must not be
        // burned on a code that cannot be verified.
        svc.publishAutoReadCode("123456")
        await settle()
        XCTAssertTrue(MockURLProtocol.capturedRequests.isEmpty)

        try await svc.initiate(phone: "+919876543210", autoSubmit: true)
        await waitForEvents(count: 2)
        svc.publishAutoReadCode("654321")
        await waitForEvents(count: 4)

        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate", "/v1/sdk/auth/verify"])
        XCTAssertEqual(try body(of: 1)["code"] as? String, "654321")
    }

    func testPublishIgnoresValuesThatAreNotCodes() async throws {
        routeByPath()
        let svc = makeService()
        var observed: [String] = []
        svc.observeOTP().sink { observed.append($0) }.store(in: &cancellables)

        try await svc.initiate(phone: "+919876543210", autoSubmit: true)
        await waitForEvents(count: 1)

        svc.publishAutoReadCode("12")            // partially typed
        svc.publishAutoReadCode("")              // cleared field
        svc.publishAutoReadCode("12ab56")        // not digits
        await settle()

        XCTAssertEqual(observed, [], "A half-typed field is not an auto-read")
        XCTAssertEqual(capturedEvents.map(name), ["otpSent"])
        XCTAssertEqual(requestPaths(), ["/v1/sdk/auth/initiate"])
    }

    func testPublishReachesBothThePublisherAndTheEventStreamExactlyOnce() async throws {
        routeByPath()
        let svc = makeService()
        var observed: [String] = []
        svc.observeOTP().sink { observed.append($0) }.store(in: &cancellables)

        try await svc.initiate(phone: "+919876543210")
        await waitForEvents(count: 1)
        svc.publishAutoReadCode("987654")
        await waitForEvents(count: 2)
        await settle()

        XCTAssertEqual(observed, ["987654"])
        XCTAssertEqual(capturedEvents.map(name), ["otpSent", "otpAutoRead"],
                       "A subscriber must not double the event a non-subscriber gets once")
    }

    // MARK: - Facade surface

    func testFacadeExposesInitializationStateAndServices() {
        _ = makeService()   // calls QuickAuth.shared.initialize
        XCTAssertTrue(QuickAuth.shared.isInitialized)
        XCTAssertNotNil(QuickAuth.shared.tokenManager)
        XCTAssertNotNil(QuickAuth.shared.whatsapp)
        XCTAssertNotNil(QuickAuth.shared.auth)
        XCTAssertNotNil(QuickAuth.shared.attribution)
        XCTAssertNotNil(QuickAuth.shared.consent)

        QuickAuth.shared.reset()
        XCTAssertFalse(QuickAuth.shared.isInitialized, "reset() must undo initialization")
    }

    func testWhatsAppServiceBuildsTheSameDeepLinkAsBefore() throws {
        let url = try XCTUnwrap(WhatsAppService.deepLink(
            businessNumber: "+91 95749 80048",
            prefilledText: "Login",
            returnURL: URL(string: "https://app.example.com/wa-return")
        ))
        XCTAssertEqual(url.host, "wa.me")
        XCTAssertEqual(url.path, "/919574980048")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first(where: { $0.name == "text" })?.value, "Login")
        XCTAssertEqual(items.first(where: { $0.name == "ref" })?.value, "https://app.example.com/wa-return")
    }

    // MARK: - Validation errors

    func testBadPhoneReportsAnArgumentErrorNotAServerError() async {
        let svc = makeService()
        do {
            try await svc.initiate(phone: "9876543210")
            XCTFail("Expected a validation failure for a non-E.164 number")
        } catch let error as QuickAuthError {
            guard case .invalidArgument = error else {
                return XCTFail("Expected .invalidArgument, got \(error)")
            }
        } catch {
            XCTFail("Expected QuickAuthError, got \(error)")
        }
    }

    private func name(_ event: AuthEvent) -> String {
        switch event {
        case .otpSent: return "otpSent"
        case .otpAutoRead: return "otpAutoRead"
        case .verified: return "verified"
        case .otpFailed: return "otpFailed"
        case .error: return "error"
        }
    }
}

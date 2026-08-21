//
//  PublishableKeyTests.swift
//  Covers the publishable-key auth mode: which credential headers go on the
//  wire in each mode, the best-effort app-identity header, and the
//  exactly-one-mode init check.
//

import XCTest
@testable import QuickAuth

final class PublishableKeyTests: XCTestCase {

    private var session: URLSession!

    private struct Body: Encodable { let phone: String }
    private struct Resp: Decodable { let ok: Bool }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/initiate")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"ok\":true}".data(using: .utf8))
        }
    }

    override func tearDown() {
        // The seam is process-global; leaving it set would leak into every
        // later test in the suite.
        APIClient.bundleIdentifierOverride = nil
        super.tearDown()
    }

    private func post(config cfg: Config) async throws -> URLRequest {
        let api = APIClient(config: { cfg }, session: session)
        let _: Resp = try await api.post(path: "/v1/sdk/auth/initiate", body: Body(phone: "+919876543210"))
        return MockURLProtocol.capturedRequests[0]
    }

    // MARK: Header selection

    func testPublishableKeyModeSendsKeyHeaderAndNoAuthorization() async throws {
        APIClient.bundleIdentifierOverride = { "com.example.testapp" }
        let cfg = try Config(apiBaseURL: URL(string: "https://api.example.test")!,
                             publishableKey: "pk_test_abc123")

        let req = try await post(config: cfg)

        XCTAssertEqual(req.value(forHTTPHeaderField: "X-QuickAuth-Key"), "pk_test_abc123")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                     "publishable-key mode must not also send a bearer token")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-QuickAuth-Bundle"), "com.example.testapp")
        // Unrelated headers must survive the new branch.
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertTrue(req.value(forHTTPHeaderField: "X-QuickAuth-SDK")?.hasPrefix("ios-sdk/") ?? false)
    }

    func testSessionModeSendsAuthorizationAndNoKeyHeader() async throws {
        // Same seam value as the keyed test, to prove the bundle header is
        // gated on the mode and not merely on identity availability.
        APIClient.bundleIdentifierOverride = { "com.example.testapp" }
        let cfg = Config(apiBaseURL: URL(string: "https://api.example.test")!,
                         onTokenExpiry: { "qa_session_token_123" })

        let req = try await post(config: cfg)

        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer qa_session_token_123")
        XCTAssertNil(req.value(forHTTPHeaderField: "X-QuickAuth-Key"))
        XCTAssertNil(req.value(forHTTPHeaderField: "X-QuickAuth-Bundle"))
    }

    func testPublishableKeyModeNeverConsultsTokenManager() async throws {
        // Built by mutation rather than through an init, because the init
        // rejects both modes at once — that is exactly why this needs its own
        // test: it proves the APIClient branch is what skips the token fetch,
        // not the absence of a provider.
        var cfg = Config(apiBaseURL: URL(string: "https://api.example.test")!,
                         onTokenExpiry: { XCTFail("TokenManager must not be consulted in publishable-key mode"); return "leaked" })
        cfg.publishableKey = "pk_test_abc123"

        let req = try await post(config: cfg)

        XCTAssertEqual(req.value(forHTTPHeaderField: "X-QuickAuth-Key"), "pk_test_abc123")
        XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: App identity is best effort

    func testMissingBundleIdentifierOmitsHeaderInsteadOfFailing() async throws {
        // Test runners, app extensions and CLI hosts all legitimately have no
        // bundle id. The request must still go out — see the fail-closed note
        // on APIClient.appBundleIdentifier() for why that is safe only while
        // app-lock is off.
        APIClient.bundleIdentifierOverride = { nil }
        let cfg = try Config(apiBaseURL: URL(string: "https://api.example.test")!,
                             publishableKey: "pk_test_abc123")

        let req = try await post(config: cfg)

        XCTAssertNil(req.value(forHTTPHeaderField: "X-QuickAuth-Bundle"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-QuickAuth-Key"), "pk_test_abc123")
    }

    func testEmptyBundleIdentifierOmitsHeader() async throws {
        APIClient.bundleIdentifierOverride = { "" }
        let cfg = try Config(apiBaseURL: URL(string: "https://api.example.test")!,
                             publishableKey: "pk_test_abc123")

        let req = try await post(config: cfg)

        XCTAssertNil(req.value(forHTTPHeaderField: "X-QuickAuth-Bundle"),
                     "an empty bundle id is no identity at all — sending it would send a blank header")
    }

    // MARK: Mode flag

    func testIsPublishableKeyModeIgnoresEmptyAndNilKeys() throws {
        let keyed = try Config(publishableKey: "pk_live_x")
        XCTAssertTrue(keyed.isPublishableKeyMode)

        var blank = Config(onTokenExpiry: { "t" })
        XCTAssertFalse(blank.isPublishableKeyMode)
        blank.publishableKey = ""
        XCTAssertFalse(blank.isPublishableKeyMode, "an empty key must not switch modes")
    }

    // MARK: Init validation

    func testBothModesSuppliedThrows() {
        XCTAssertThrowsError(
            try Config(publishableKey: "pk_test_abc123", onTokenExpiry: { "tok" })
        ) { error in
            guard case QuickAuthError.invalidConfiguration(let message) = error else {
                return XCTFail("Expected .invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(message.contains("not both"), "error must name the problem: \(message)")
        }
    }

    func testNeitherModeSuppliedThrows() {
        XCTAssertThrowsError(
            try Config(publishableKey: nil)
        ) { error in
            guard case QuickAuthError.invalidConfiguration(let message) = error else {
                return XCTFail("Expected .invalidConfiguration, got \(error)")
            }
            XCTAssertTrue(message.contains("publishableKey") && message.contains("onTokenExpiry"),
                          "error must name both options: \(message)")
        }
    }

    func testEmptyPublishableKeyCountsAsNoModeSupplied() {
        // A stripped build-time substitution ("") is the realistic way to get
        // here, and it must fail at init rather than as a 401 on device.
        XCTAssertThrowsError(try Config(publishableKey: ""))
    }

    func testFacadeInitializeRejectsBothModes() {
        XCTAssertThrowsError(
            try QuickAuth.shared.initialize(publishableKey: "pk_test_abc123", onTokenExpiry: { "tok" })
        )
    }

    func testFacadeInitializeAcceptsPublishableKey() throws {
        try QuickAuth.shared.initialize(publishableKey: "pk_test_abc123",
                                        apiBaseURL: URL(string: "https://api.example.test")!)
        XCTAssertTrue(QuickAuth.shared.config.isPublishableKeyMode)
        XCTAssertEqual(QuickAuth.shared.config.publishableKey, "pk_test_abc123")
        QuickAuth.shared.reset()
    }
}

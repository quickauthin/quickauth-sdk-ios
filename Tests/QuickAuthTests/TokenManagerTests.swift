//
//  TokenManagerTests.swift
//  Covers single-flight refresh, expiry-aware refresh, JWT parsing,
//  invalidate(), and the unsafe-direct-mint path.
//

import XCTest
@testable import QuickAuth

final class TokenManagerTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
    }

    // MARK: helpers

    /// Build a JWT-like string with the given exp (seconds since epoch).
    /// The header & signature are bogus — only the middle segment is parsed.
    private func makeJWT(exp: TimeInterval, extraClaims: [String: Any] = [:]) -> String {
        var payload = extraClaims
        payload["exp"] = exp
        let payloadData = try! JSONSerialization.data(withJSONObject: payload)
        let payloadB64 = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payloadB64).sig"
    }

    private func config(
        onTokenExpiry: @escaping TokenProvider,
        initialToken: String? = nil
    ) -> Config {
        Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: onTokenExpiry,
            initialToken: initialToken
        )
    }

    // MARK: tests

    func testGetTokenInvokesProviderWhenAbsent() async throws {
        let calls = ProviderCounter()
        let cfg = config(onTokenExpiry: {
            await calls.increment()
            return "fresh"
        })
        let mgr = TokenManager(config: { cfg }, session: session)

        let t = try await mgr.getToken()
        XCTAssertEqual(t, "fresh")
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testInitialTokenIsAdoptedWithoutCallingProvider() async throws {
        let exp = Date().addingTimeInterval(600).timeIntervalSince1970
        let jwt = makeJWT(exp: exp)
        let calls = ProviderCounter()
        let cfg = config(
            onTokenExpiry: {
                await calls.increment()
                return "should-not-be-called"
            },
            initialToken: jwt
        )
        let mgr = TokenManager(config: { cfg }, session: session)

        let t = try await mgr.getToken()
        XCTAssertEqual(t, jwt)
        let count = await calls.count
        XCTAssertEqual(count, 0)
    }

    func testExpiringTokenTriggersRefresh() async throws {
        // Token with exp 10s in the future → inside the 30s leeway → refresh.
        let exp = Date().addingTimeInterval(10).timeIntervalSince1970
        let oldJWT = makeJWT(exp: exp)
        let newJWT = makeJWT(exp: Date().addingTimeInterval(600).timeIntervalSince1970)

        let cfg = config(
            onTokenExpiry: { newJWT },
            initialToken: oldJWT
        )
        let mgr = TokenManager(config: { cfg }, session: session)

        let t = try await mgr.getToken()
        XCTAssertEqual(t, newJWT)
    }

    func testCachedTokenIsReusedWhenNotExpiring() async throws {
        let exp = Date().addingTimeInterval(600).timeIntervalSince1970
        let jwt = makeJWT(exp: exp)
        let calls = ProviderCounter()
        let cfg = config(onTokenExpiry: {
            await calls.increment()
            return jwt
        })
        let mgr = TokenManager(config: { cfg }, session: session)

        let a = try await mgr.getToken()
        let b = try await mgr.getToken()
        let c = try await mgr.getToken()
        XCTAssertEqual(a, b)
        XCTAssertEqual(b, c)
        let count = await calls.count
        XCTAssertEqual(count, 1, "subsequent gets should not refetch")
    }

    func testInvalidateForcesRefetch() async throws {
        let calls = ProviderCounter()
        let cfg = config(onTokenExpiry: {
            await calls.increment()
            let exp = Date().addingTimeInterval(600).timeIntervalSince1970
            return "tok-\(await calls.count)-\(exp)"
        })
        let mgr = TokenManager(config: { cfg }, session: session)

        _ = try await mgr.getToken()
        await mgr.invalidate()
        _ = try await mgr.getToken()

        let count = await calls.count
        XCTAssertEqual(count, 2)
    }

    func testSingleFlightCoalescesConcurrentGets() async throws {
        let calls = ProviderCounter()
        let cfg = config(onTokenExpiry: {
            await calls.increment()
            // Slow down so concurrent waiters pile up.
            try? await Task.sleep(nanoseconds: 100_000_000)
            let exp = Date().addingTimeInterval(600).timeIntervalSince1970
            return "tok-exp-\(exp)"
        })
        let mgr = TokenManager(config: { cfg }, session: session)

        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<10 {
                group.addTask { try await mgr.getToken() }
            }
            var out: [String] = []
            for try await v in group { out.append(v) }
            return out
        }

        XCTAssertEqual(results.count, 10)
        XCTAssertEqual(Set(results).count, 1, "all callers should observe the same token")
        let count = await calls.count
        XCTAssertEqual(count, 1, "provider should be invoked exactly once under single-flight")
    }

    func testJWTExpiryParsingHandlesBase64URL() {
        let exp = Date().addingTimeInterval(123).timeIntervalSince1970
        let jwt = makeJWT(exp: exp)
        let parsed = TokenManager.expiryDate(fromJWT: jwt)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.timeIntervalSince1970, exp, accuracy: 0.001)
    }

    func testJWTExpiryParsingReturnsNilForGarbage() {
        XCTAssertNil(TokenManager.expiryDate(fromJWT: "not-a-jwt"))
        XCTAssertNil(TokenManager.expiryDate(fromJWT: "a.b"))
        XCTAssertNil(TokenManager.expiryDate(fromJWT: "a.@@@.c"))
    }

    func testUnsafeDirectMintCallsSessionEndpoint() async throws {
        MockURLProtocol.requestHandler = { req in
            // Verify it hit the right endpoint with the right headers.
            XCTAssertEqual(req.url?.path, "/v1/sdk/session")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Client-Id"), "cid_123")
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Client-Secret"), "secret_xyz")
            let r = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"session_token\":\"minted-tok\"}".data(using: .utf8))
        }
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            unsafeDirectClientId: "cid_123",
            unsafeDirectClientSecret: "secret_xyz"
        )
        let mgr = TokenManager(config: { cfg }, session: session)
        let t = try await mgr.getToken()
        XCTAssertEqual(t, "minted-tok")
    }

    func testProviderEmptyTokenSurfacesAsError() async {
        let cfg = config(onTokenExpiry: { "" })
        let mgr = TokenManager(config: { cfg }, session: session)
        do {
            _ = try await mgr.getToken()
            XCTFail("expected throw")
        } catch QuickAuthError.tokenProviderFailed {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

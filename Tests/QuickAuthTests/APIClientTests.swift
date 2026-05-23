//
//  APIClientTests.swift
//

import XCTest
@testable import QuickAuth

final class APIClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        session = URLSession.mocked()
    }

    private func makeClient(
        onTokenExpiry: @escaping TokenProvider = { "test-token" },
        initialToken: String? = nil
    ) -> APIClient {
        let cfg = Config(
            apiBaseURL: URL(string: "https://api.example.test")!,
            onTokenExpiry: onTokenExpiry,
            initialToken: initialToken
        )
        return APIClient(config: { cfg }, session: session)
    }

    func testPostSendsAuthHeaderAndIdempotencyKey() async throws {
        struct Body: Encodable { let phone: String }
        struct Resp: Decodable { let ok: Bool }

        MockURLProtocol.requestHandler = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.example.test/v1/x")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "{\"ok\": true}".data(using: .utf8))
        }

        let api = makeClient(initialToken: "qa_session_token_123")
        let _: Resp = try await api.post(path: "/v1/x", body: Body(phone: "+91"))

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.test/v1/x")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer qa_session_token_123")
        XCTAssertNotNil(req.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(req.value(forHTTPHeaderField: "X-QuickAuth-SDK")?.hasPrefix("ios-sdk/") ?? false)

        let body = try XCTUnwrap(req.httpBody)
        let dict = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(dict?["phone"] as? String, "+91")
    }

    func testTokenProviderInvokedWhenNoInitialToken() async throws {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }

        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"ok\":true}".data(using: .utf8))
        }

        let providerCalls = ProviderCounter()
        let api = makeClient(onTokenExpiry: {
            await providerCalls.increment()
            return "fresh-token-abc"
        })
        let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))

        let count = await providerCalls.count
        XCTAssertEqual(count, 1)
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token-abc")
    }

    func testNotInitializedWhenProviderThrows() async {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }
        let api = makeClient(onTokenExpiry: { throw QuickAuthError.notInitialized })
        do {
            let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))
            XCTFail("expected throw")
        } catch QuickAuthError.notInitialized {
            // ok
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testHTTPErrorPropagatesStatus() async {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                    statusCode: 422, httpVersion: nil, headerFields: nil)!
            return (r, "{\"error\":\"bad\"}".data(using: .utf8))
        }
        let api = makeClient(initialToken: "tkn")
        do {
            let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))
            XCTFail("expected throw")
        } catch QuickAuthError.http(let status, _) {
            XCTAssertEqual(status, 422)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func testRetriesOn5xx() async throws {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }

        let counter = AttemptCounter()
        MockURLProtocol.requestHandler = { _ in
            let n = counter.next() // 0-indexed
            if n < 1 {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                        statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (r, Data())
            } else {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"ok\":true}".data(using: .utf8))
            }
        }
        let api = makeClient(initialToken: "tkn")
        let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))
        XCTAssertEqual(counter.value, 2)
    }

    func testVerifyResponseDecodesNewShape() async throws {
        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/sdk/auth/verify")!,
                                    statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (r, "{\"verified\":true,\"requestId\":\"req_abc\",\"message\":\"Verified successfully\"}".data(using: .utf8))
        }
        struct Req: Encodable { let sessionId: String; let code: String }
        let api = makeClient(initialToken: "tkn")
        let resp: OTPVerification = try await api.post(path: "/v1/sdk/auth/verify",
                                                       body: Req(sessionId: "s1", code: "111111"))
        XCTAssertTrue(resp.verified)
        XCTAssertEqual(resp.requestId, "req_abc")
        XCTAssertEqual(resp.message, "Verified successfully")
    }

    func test401InvalidatesAndRetriesOnce() async throws {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }

        let counter = AttemptCounter()
        MockURLProtocol.requestHandler = { _ in
            let n = counter.next()
            if n == 0 {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                        statusCode: 401, httpVersion: nil, headerFields: nil)!
                return (r, "{\"error\":\"unauthorized\"}".data(using: .utf8))
            } else {
                let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                        statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (r, "{\"ok\":true}".data(using: .utf8))
            }
        }

        let providerCalls = ProviderCounter()
        let api = makeClient(onTokenExpiry: {
            await providerCalls.increment()
            let n = await providerCalls.count
            return "tkn-\(n)"
        })

        let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))

        XCTAssertEqual(counter.value, 2, "should have retried once after 401")
        let providerCount = await providerCalls.count
        XCTAssertEqual(providerCount, 2, "expected token to be re-fetched after invalidate")
        XCTAssertEqual(MockURLProtocol.capturedRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer tkn-1")
        XCTAssertEqual(MockURLProtocol.capturedRequests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tkn-2")
    }

    func test401SecondFailureSurfacesError() async {
        struct Body: Encodable { let x: Int }
        struct Resp: Decodable { let ok: Bool }

        MockURLProtocol.requestHandler = { _ in
            let r = HTTPURLResponse(url: URL(string: "https://api.example.test/v1/y")!,
                                    statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (r, "{\"error\":\"unauthorized\"}".data(using: .utf8))
        }
        let api = makeClient(initialToken: "tkn")
        do {
            let _: Resp = try await api.post(path: "/v1/y", body: Body(x: 1))
            XCTFail("expected 401 to surface after retry")
        } catch QuickAuthError.http(let status, _) {
            XCTAssertEqual(status, 401)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}

// MARK: - Test helpers

actor ProviderCounter {
    private(set) var count: Int = 0
    func increment() { count += 1 }
}

final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        let v = _value
        _value += 1
        return v
    }
}

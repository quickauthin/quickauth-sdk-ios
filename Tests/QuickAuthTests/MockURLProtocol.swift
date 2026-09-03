//
//  MockURLProtocol.swift
//  Test-only URLProtocol that lets us mock URLSession traffic.
//

import Foundation

final class MockURLProtocol: URLProtocol {

    // Requests are loaded on URLSession's own threads, and a test that triggers
    // work it does not await (auto-submit) can have one in flight while the next
    // test's setUp resets these. Unsynchronised, that is a data race on a Swift
    // Array — which showed up as an intermittent SIGSEGV in the whole-suite run,
    // not as a test failure.
    private static let lock = NSLock()
    private static var _requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))?
    private static var _capturedRequests: [URLRequest] = []

    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data?))? {
        get { lock.lock(); defer { lock.unlock() }; return _requestHandler }
        set { lock.lock(); _requestHandler = newValue; lock.unlock() }
    }

    static var capturedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return _capturedRequests
    }

    private static func capture(_ request: URLRequest) {
        lock.lock(); _capturedRequests.append(request); lock.unlock()
    }

    static func reset() {
        lock.lock()
        _requestHandler = nil
        _capturedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // Capture body too — URLProtocol strips httpBody for streamed bodies; use httpBodyStream as fallback.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 1024
            var buffer = [UInt8](repeating: 0, count: bufferSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: bufferSize)
                if read > 0 { data.append(buffer, count: read) }
                else { break }
            }
            captured.httpBody = data
        }
        Self.capture(captured)

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        do {
            let (response, data) = try handler(captured)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension URLSession {
    static func mocked() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

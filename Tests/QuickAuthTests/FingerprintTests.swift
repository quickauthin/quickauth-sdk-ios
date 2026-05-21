//
//  FingerprintTests.swift
//

import XCTest
@testable import QuickAuth

final class FingerprintTests: XCTestCase {

    func testDeterministicForFixedInputs() {
        let a = Fingerprint(
            timezone: "Asia/Kolkata",
            locale: "en_IN",
            language: "en-IN",
            region: "IN",
            screenWidth: 390,
            screenHeight: 844,
            scale: 3.0,
            userAgent: "QuickAuth/0.1.0 (iOS 17.0)",
            idfa: nil
        )
        let b = Fingerprint(
            timezone: "Asia/Kolkata",
            locale: "en_IN",
            language: "en-IN",
            region: "IN",
            screenWidth: 390,
            screenHeight: 844,
            scale: 3.0,
            userAgent: "QuickAuth/0.1.0 (iOS 17.0)",
            idfa: nil
        )
        XCTAssertEqual(a, b)
    }

    func testCurrentReturnsValidFields() {
        let fp = Fingerprint.current()
        XCTAssertFalse(fp.timezone.isEmpty)
        XCTAssertFalse(fp.locale.isEmpty)
        XCTAssertFalse(fp.userAgent.isEmpty)
        // IDFA must be nil unless ATT is authorized — in tests it shouldn't be.
        XCTAssertNil(fp.idfa)
    }

    func testEncodableProducesSnakeCaseKeys() throws {
        let fp = Fingerprint(
            timezone: "UTC",
            locale: "en_US",
            language: "en",
            region: "US",
            screenWidth: 100,
            screenHeight: 200,
            scale: 1,
            userAgent: "ua",
            idfa: nil
        )
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let data = try enc.encode(fp)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["screen_width"] as? Int, 100)
        XCTAssertEqual(json["user_agent"] as? String, "ua")
    }
}

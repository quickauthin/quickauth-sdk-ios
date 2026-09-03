//
//  PackagingTests.swift
//  Guards on the two things that are easy to get quietly wrong at release
//  time: the SDK version having a second copy, and the privacy manifest not
//  shipping.
//

import XCTest
@testable import QuickAuth

final class PackagingTests: XCTestCase {

    /// Repo root, derived from this file's own path (…/Tests/QuickAuthTests/X.swift).
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // QuickAuthTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Version single-sourcing

    func testPodspecDerivesItsVersionFromConfigRatherThanRestatingIt() throws {
        let podspec = try read("QuickAuthIn.podspec")

        // A literal here is the failure mode this test exists to catch: two
        // copies of the version, one of which will be forgotten on release.
        let literal = try NSRegularExpression(pattern: #"s\.version\s*=\s*['"]"#)
        let range = NSRange(podspec.startIndex..., in: podspec)
        XCTAssertNil(
            literal.firstMatch(in: podspec, range: range),
            "QuickAuthIn.podspec must read the version from Config.currentSDKVersion, not declare its own"
        )
        XCTAssertTrue(
            podspec.contains("Sources', 'QuickAuth', 'Core', 'Config.swift"),
            "QuickAuthIn.podspec should point at Config.swift as the version source"
        )
    }

    /// Run the podspec's own extraction against Config.swift and check it lands
    /// on the constant the SDK reports at runtime.
    func testPodspecRegexRecoversTheRuntimeSDKVersion() throws {
        let configSource = try read("Sources/QuickAuth/Core/Config.swift")
        let regex = try NSRegularExpression(pattern: #"currentSDKVersion\s*=\s*"([^"]+)""#)
        let range = NSRange(configSource.startIndex..., in: configSource)
        let match = try XCTUnwrap(regex.firstMatch(in: configSource, range: range),
                                  "The podspec's regex no longer matches Config.swift")
        let captured = String(configSource[Range(match.range(at: 1), in: configSource)!])

        XCTAssertEqual(captured, Config.currentSDKVersion)
        XCTAssertTrue(
            captured.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
            "Version must stay plain semver; the pod tag is built from it"
        )
    }

    func testSDKVersionHeaderUsesTheSingleSource() {
        let cfg = Config(onTokenExpiry: { "t" })
        XCTAssertEqual(cfg.sdkVersion, Config.currentSDKVersion)
        XCTAssertEqual("ios-sdk/\(cfg.sdkVersion)", "ios-sdk/\(Config.currentSDKVersion)")
    }

    // MARK: - Privacy manifest

    func testPrivacyManifestShipsAndParses() throws {
        let url = repoRoot.appendingPathComponent("Sources/QuickAuth/PrivacyInfo.xcprivacy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "App Store review requires a privacy manifest for third-party SDKs")

        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        XCTAssertNotNil(plist["NSPrivacyTracking"] as? Bool)
        XCTAssertNotNil(plist["NSPrivacyTrackingDomains"] as? [String])
        XCTAssertFalse((plist["NSPrivacyCollectedDataTypes"] as? [[String: Any]] ?? []).isEmpty)

        // Storage.swift reads and writes UserDefaults, which is a
        // required-reason API: shipping without the declaration is a rejection.
        let accessed = plist["NSPrivacyAccessedAPITypes"] as? [[String: Any]] ?? []
        let userDefaults = accessed.first {
            $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults"
        }
        let reasons = try XCTUnwrap(userDefaults?["NSPrivacyAccessedAPITypeReasons"] as? [String])
        XCTAssertFalse(reasons.isEmpty)
    }

    func testPrivacyManifestIsDeclaredToBothPackageManagers() throws {
        let package = try read("Package.swift")
        XCTAssertTrue(package.contains("PrivacyInfo.xcprivacy"),
                      "SPM consumers get the manifest only if the target declares it as a resource")

        let podspec = try read("QuickAuthIn.podspec")
        XCTAssertTrue(podspec.contains("resource_bundles"),
                      "CocoaPods consumers get the manifest only via a resource bundle")
        XCTAssertTrue(podspec.contains("PrivacyInfo.xcprivacy"))
    }
}

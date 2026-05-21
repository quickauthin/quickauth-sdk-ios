//
//  DeviceInfo.swift
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct DeviceInfo: Encodable, Equatable {
    public let platform: String
    public let osVersion: String
    public let deviceModel: String
    public let appVersion: String
    public let appBuild: String
    public let bundleId: String
    public let installId: String
    public let sdkVersion: String

    public static func current(sdkVersion: String) -> DeviceInfo {
        let bundle = Bundle.main
        let appVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let appBuild   = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let bundleId   = bundle.bundleIdentifier ?? "unknown"

        var osVersion = "0"
        var deviceModel = "unknown"
        #if canImport(UIKit)
        osVersion = UIDevice.current.systemVersion
        deviceModel = Self.machineIdentifier() ?? UIDevice.current.model
        #endif

        return DeviceInfo(
            platform: "ios",
            osVersion: osVersion,
            deviceModel: deviceModel,
            appVersion: appVersion,
            appBuild: appBuild,
            bundleId: bundleId,
            installId: Storage.installID(),
            sdkVersion: sdkVersion
        )
    }

    /// Marketing-style hardware identifier (e.g. "iPhone15,2").
    private static func machineIdentifier() -> String? {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.reduce(into: "") { (acc, element) in
            if let value = element.value as? Int8, value != 0 {
                acc.append(String(UnicodeScalar(UInt8(value))))
            }
        }
        return id.isEmpty ? nil : id
    }
}

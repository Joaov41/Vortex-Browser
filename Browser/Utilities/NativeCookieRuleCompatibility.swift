import Foundation
import Darwin

enum NativeCookieRuleCompatibility {
    static var isSupported: Bool {
        supports(
            majorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
            osBuild: operatingSystemBuild,
            sdkBuild: Bundle.main.object(forInfoDictionaryKey: "DTSDKBuild") as? String
        )
    }

    /// iOS 26 keeps its existing path. iOS 27 is enabled only for the OS/SDK
    /// pair exercised by the isolated lifecycle and cookie probe on the M1 iPad.
    /// Re-run scripts/WebKitRegressionProbe before extending this allowlist.
    static func supports(majorVersion: Int, osBuild: String, sdkBuild: String?) -> Bool {
        if majorVersion < 27 { return true }
        return majorVersion == 27 && osBuild == "24A5430a" && sdkBuild == "24A5380g"
    }

    private static var operatingSystemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
    }
}

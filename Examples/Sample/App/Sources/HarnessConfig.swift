import Foundation

/// Build-time configuration, injected via `Config/*.xcconfig` → Info.plist.
///
/// The backend is chosen by picking a build configuration, never at runtime: the SDK
/// keeps `installationId` and the device secret per install, so one install retargeted
/// at another backend would present a secret that backend never issued. The per-config
/// bundle id gives each environment its own install, and therefore its own SDK state.
enum HarnessConfig {
    static var baseUrl: String { string("ArselBaseUrl") }
    static var clientKey: String { string("ArselClientKey") }

    /// Empty until an App Group is provisioned; nil leaves the SDK's NSE mirroring off.
    static var appGroupId: String? { optionalString("ArselAppGroupId") }
    static var keychainAccessGroup: String? { optionalString("ArselKeychainAccessGroup") }

    /// Enough of the key to recognize it in a screenshot, no more.
    static var clientKeyPreview: String {
        clientKey.count > 12 ? String(clientKey.prefix(12)) + "…" : clientKey
    }

    private static func string(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
    }

    private static func optionalString(_ key: String) -> String? {
        let value = string(key)
        return value.isEmpty ? nil : value
    }
}

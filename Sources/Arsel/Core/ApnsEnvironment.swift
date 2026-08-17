import Foundation

/// Which APNs host this build's device tokens are addressable on.
///
/// The token itself carries no hint, and a sandbox token sent to the production
/// host is rejected outright, so the SDK reports it at registration. The
/// entitlement embedded in the provisioning profile is the only thing that
/// actually decides which host APNs minted the token for — `DEBUG` is a compile
/// flag and says nothing about how the app was signed, which is how a TestFlight
/// build compiled with debug symbols ends up silently unreachable.
enum ApnsEnvironment {
    static let production = "production"
    static let sandbox = "sandbox"

    /// Resolved once: the profile cannot change while the process is running.
    static let current: String = resolve()

    static func resolve(
        bundle: Bundle = .main,
        isSimulator: Bool = defaultIsSimulator
    ) -> String {
        // The simulator has no provisioning profile and only ever talks to sandbox.
        if isSimulator { return sandbox }

        guard let url = bundle.url(
                forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let text = String(data: raw, encoding: .isoLatin1) else {
            // App Store builds strip the profile, and that is the only common
            // case where it is missing — production is the correct read.
            return production
        }
        return text.contains("<key>aps-environment</key>")
            && apsEnvironmentValue(in: text) == "development"
            ? sandbox
            : production
    }

    /// The profile is a CMS blob with a plist inside, so the value is read by
    /// scanning rather than by parsing — a full CMS decode would need Security
    /// framework work for one string.
    private static func apsEnvironmentValue(in text: String) -> String? {
        guard let keyRange = text.range(of: "<key>aps-environment</key>"),
              let open = text.range(of: "<string>", range: keyRange.upperBound..<text.endIndex),
              let close = text.range(of: "</string>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static var defaultIsSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }
}

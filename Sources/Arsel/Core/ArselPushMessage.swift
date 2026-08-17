import Foundation

/// One action button carried in `arsel_actions`.
public struct ArselPushAction: Sendable {
    public let actionId: String
    public let label: String
    public let deepLink: String?
}

/// An Arsel push parsed from the APNs `userInfo` dictionary.
public struct ArselPushMessage: Sendable {
    public let messageId: String
    public let wireVersion: String?
    public let signature: String?
    public let keyId: String?
    public let title: String?
    public let body: String?
    public let imageUrl: String?
    public let deepLink: String?
    public let collapseId: String?
    public let actions: [ArselPushAction]

    /// Cheap claim check for hosts multiplexing several push sources. The envelope
    /// is identified by `arsel_v`, with `arsel_mid` as the fallback for a future
    /// envelope that drops the version.
    public static func isArsel(userInfo: [AnyHashable: Any]) -> Bool {
        if let version = userInfo[Wire.DataKey.version] as? String, !version.isEmpty { return true }
        if let mid = userInfo[Wire.DataKey.messageId] as? String, !mid.isEmpty { return true }
        return false
    }

    /// Returns nil when `userInfo` is not an Arsel push, or carries no usable message id.
    public static func from(userInfo: [AnyHashable: Any]) -> ArselPushMessage? {
        guard isArsel(userInfo: userInfo) else { return nil }
        guard let id = userInfo[Wire.DataKey.messageId] as? String, !id.isEmpty else { return nil }
        return ArselPushMessage(
            messageId: id,
            wireVersion: userInfo[Wire.DataKey.version] as? String,
            signature: userInfo[Wire.DataKey.signature] as? String,
            keyId: userInfo[Wire.DataKey.signatureKeyId] as? String,
            title: userInfo[Wire.DataKey.title] as? String,
            body: userInfo[Wire.DataKey.body] as? String,
            imageUrl: userInfo[Wire.DataKey.image] as? String,
            deepLink: userInfo[Wire.DataKey.deepLink] as? String,
            collapseId: userInfo[Wire.DataKey.collapseId] as? String,
            actions: parseActions(userInfo[Wire.DataKey.actions] as? String))
    }

    /// `arsel_actions` is a JSON array of `{actionId, label, deepLink}` objects,
    /// carried as a string. Malformed entries are skipped, never fatal.
    static func parseActions(_ raw: String?) -> [ArselPushAction] {
        guard let raw, !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return parsed.compactMap { entry in
            guard let actionId = entry["actionId"] as? String, !actionId.isEmpty,
                  let label = entry["label"] as? String else { return nil }
            return ArselPushAction(
                actionId: actionId,
                label: label,
                deepLink: entry["deepLink"] as? String)
        }
    }
}

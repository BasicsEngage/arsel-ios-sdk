import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The Notification Service Extension helper — the Klaviyo `KlaviyoSwiftExtension`
/// pattern. Two jobs, both best-effort:
///
/// 1. engagement `delivered` the moment the push reaches the device (the only
///    device-side delivery signal iOS offers), and
/// 2. download `arsel_image` and attach it, so rich pushes render.
///
/// **NSE execution is not guaranteed.** iOS only launches the extension when the
/// APNs payload carries `mutable-content: 1`, skips it under low power or storage
/// pressure, and kills it hard at ~30 seconds. `delivered` counts are therefore a
/// floor, never a total — the backend knows this and treats them accordingly.
public enum ArselNotificationExtensionHandler {
    #if canImport(UserNotifications)
    /// Call as the first line of your extension's
    /// `didReceive(_:withContentHandler:)`. Returns `false` when the notification
    /// is not Arsel's — serve your own logic and call the handler yourself. When it
    /// returns `true`, the SDK will invoke `contentHandler` (always — a failed
    /// download or engagement never eats the notification).
    ///
    /// - Parameters:
    ///   - appGroupId: the App Group shared with the main app, where the SDK
    ///     mirrored its context. Without it the engagement cannot be sent.
    public static func didReceive(
        _ request: UNNotificationRequest,
        appGroupId: String,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) -> Bool {
        let userInfo = request.content.userInfo
        guard let messageId = userInfo[ExtensionWire.messageIdKey] as? String, !messageId.isEmpty else {
            return false
        }

        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()

        if let context = ExtensionContext.load(appGroupId: appGroupId) {
            sendDeliveredEngagement(
                context: context,
                messageId: messageId,
                signature: userInfo[ExtensionWire.signatureKey] as? String,
                signatureKeyId: userInfo[ExtensionWire.signatureKeyIdKey] as? String)
        }

        if let imageUrl = userInfo[ExtensionWire.imageKey] as? String, let url = URL(string: imageUrl) {
            attachImage(from: url, to: content) { contentHandler(content) }
        } else {
            contentHandler(content)
        }
        return true
    }

    /// Fire-and-forget with a short leash: the extension's ~30s budget belongs to
    /// the attachment download and the handler, not to an engagement retry. A missed
    /// `delivered` is an accepted loss (it is a floor metric); the queue-and-retry
    /// machinery lives in the main SDK, not here.
    private static func sendDeliveredEngagement(
        context: ExtensionContext,
        messageId: String,
        signature: String?,
        signatureKeyId: String?
    ) {
        #if canImport(Security)
        guard let secret = ExtensionSecret.read(accessGroup: context.keychainAccessGroup) else {
            // No shared keychain access group configured, or the app never
            // registered. Documented limitation: no engagement without the secret.
            return
        }
        let body = ExtensionEngagement.deliveredBody(
            installationId: context.installationId,
            messageId: messageId,
            signature: signature,
            signatureKeyId: signatureKeyId)
        guard let url = URL(string: context.baseUrl + ExtensionWire.engagementsPath(clientKey: context.clientKey)),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = data
        urlRequest.timeoutInterval = 10
        urlRequest.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(ExtensionWire.sdkHeaderValue, forHTTPHeaderField: ExtensionWire.sdkHeader)
        urlRequest.setValue(secret, forHTTPHeaderField: ExtensionWire.deviceAuthHeader)
        URLSession.shared.dataTask(with: urlRequest).resume()
        #endif
    }

    private static func attachImage(
        from url: URL,
        to content: UNMutableNotificationContent,
        completion: @escaping () -> Void
    ) {
        let task = URLSession.shared.downloadTask(with: url) { location, response, _ in
            defer { completion() }
            guard let location else { return }
            // UNNotificationAttachment needs a stable file with a recognizable
            // extension; the download's temp name has neither.
            let ext = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                let attachment = try UNNotificationAttachment(
                    identifier: "arsel_image", url: destination)
                content.attachments = [attachment]
            } catch {
                // The push still shows, just without the picture.
            }
        }
        task.resume()
    }
    #endif
}

import SwiftUI
import UIKit
import Arsel

/// End-to-end harness for the Arsel iOS SDK, mirroring the Android sample screen.
///
/// Everything SDK-owned on screen is read back through the SDK's own public surface —
/// `diagnostics()` and `Arsel.anonymousId` — so what you see here is exactly what an
/// integrator can see in the field. There is no privileged back channel, and adding one
/// would make this a worse test of the SDK.
struct ContentView: View {
    @ObservedObject private var log = SdkEventLog.shared
    @ObservedObject private var state = HarnessState.shared

    @State private var eventName = "product.viewed"
    @State private var propKey = "sku"
    @State private var propValue = "A-1023"
    @State private var externalId = "user_10294"
    @State private var email = ""
    @State private var phoneNumber = ""

    @State private var installationId = "(pending)"
    @State private var anonymousId = "(pending)"
    @State private var diagnosticsText = "(pending)"
    /// Last condensed diagnostics line, so the poll only logs when something moved.
    @State private var lastLoggedDiagnostics: String?

    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                Divider()
                eventsSection
                Divider()
                identitySection
                Divider()
                actionsSection
                Divider()
                diagnosticsSection
                logSection
            }
            .padding()
        }
        .onAppear { refreshDiagnostics() }
        .onReceive(poll) { _ in refreshDiagnostics() }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Arsel Push — test harness").font(.title2.bold())

            // Which backend this build talks to. Two configurations install side by side,
            // so a screenshot or a debugging session is ambiguous without it.
            fieldLabel("Backend")
            monoText("\(HarnessConfig.baseUrl)\n\(HarnessConfig.clientKeyPreview)")

            fieldLabel("Installation ID — names the DEVICE, survives logout")
            monoText(installationId)

            fieldLabel("Anonymous ID — names the PERSON, rotated by reset()")
            monoText(anonymousId)

            fieldLabel("APNs token — host-side, from the AppDelegate")
            monoText(state.apnsTokenHex ?? "(none yet — simulators may never get one)")
            copyButton("Copy APNs token", value: state.apnsTokenHex)
        }
    }

    private var eventsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events").font(.headline)
            noteText("Events need no push token, no notification permission and no APNs. "
                + "Track something before identifying and watch it follow you across the merge.")

            harnessField("product.viewed", text: $eventName)
            HStack {
                harnessField("sku", text: $propKey)
                harnessField("A-1023", text: $propValue)
            }
            actionButton("track()") { trackEvent() }
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Identity").font(.headline)
            noteText("identify() merges everything tracked anonymously onto the contact it "
                + "resolves to. The push subscription follows on its own — registration carries "
                + "the anonymous id, so the device lands on the same contact its events do.")

            fieldLabel("identify(…) — client-asserted, merges the anonymous history")
            harnessField("externalId  e.g. user_10294", text: $externalId)
            harnessField("email (optional)", text: $email)
            harnessField("phone, E.164 (optional)  e.g. +966501234567", text: $phoneNumber)
            actionButton("identify(externalId / email / phone)") { identifyWithFields() }
            actionButton("Run the merge proof (track → identify → track)") { runMergeProof() }

            noteText("To assert the binding from a server instead, send the installation id "
                + "above to your backend and have it call POST /v1/push/devices with your "
                + "secret API key. That key must never ship in an app binary.")
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Actions").font(.headline)
            noteText("Never press these and everything above still works. That is the point: on "
                + "a fresh install, track() and identify() build a contact with a real event "
                + "history while enablementStatus stays NOT_DETERMINED.")

            actionButton("Request notification permission") { requestPermission() }
            actionButton("flushNow()") { flushNow() }
            actionButton("reset() — logout, stays subscribed") { resetIdentity() }
            actionButton("optOut() — DURABLE, not resurrectable") { optOut() }
        }
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Diagnostics").font(.headline)
            monoText(diagnosticsText)
            copyButton("Copy diagnostics", value: diagnosticsText)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SDK event log (newest first)").font(.headline)
            monoText(log.snapshot)
            actionButton("Clear log") { log.clear() }
        }
    }

    // MARK: Actions

    private func trackEvent() {
        let name = eventName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            log.log("track() skipped — give the event a name first")
            return
        }
        let properties = propertyPair()
        log.log("-> track(\"\(name)\", \(properties))")
        Arsel.track(name, properties: properties)
    }

    /// One optional key/value pair — enough to prove properties reach the wire intact.
    /// Numbers stay numbers: a property that arrives as "149.99" fails a numeric event
    /// schema on the backend, and that is a real integration mistake worth reproducing.
    private func propertyPair() -> [String: Any] {
        let key = propKey.trimmingCharacters(in: .whitespaces)
        let value = propValue.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !value.isEmpty else { return [:] }
        if let intValue = Int(value) { return [key: intValue] }
        if let doubleValue = Double(value) { return [key: doubleValue] }
        return [key: value]
    }

    private func identifyWithFields() {
        let id = externalId.trimmingCharacters(in: .whitespaces)
        let mail = email.trimmingCharacters(in: .whitespaces)
        let phone = phoneNumber.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty || !mail.isEmpty || !phone.isEmpty else {
            log.log("identify() skipped — fill in at least one identifier")
            return
        }
        log.log("-> identify(externalId=\(id.isEmpty ? "nil" : id), "
            + "email=\(mail.isEmpty ? "nil" : mail), phone=\(phone.isEmpty ? "nil" : phone))")
        Arsel.identify(
            externalId: id.isEmpty ? nil : id,
            email: mail.isEmpty ? nil : mail,
            phoneNumber: phone.isEmpty ? nil : phone)
    }

    /// The end-to-end proof that an anonymous history survives identification.
    ///
    /// Tracks under the anonymous id, identifies, then tracks again. On the backend both
    /// events must end up on ONE contact — the anonymous one merged into the identified
    /// one. The anonymous id shown before and after is the same, which is what makes the
    /// merge observable from here: the SDK rotates it on `reset()`, never on identify.
    private func runMergeProof() {
        let id = externalId.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            log.log("merge proof skipped — enter an external ID first")
            return
        }
        log.log("MERGE PROOF — anonymous id before: \(Arsel.anonymousId ?? "(none)")")
        Arsel.track("merge.before_identify", properties: ["stage": "anonymous"])
        Arsel.identify(externalId: id)
        Arsel.track("merge.after_identify", properties: ["stage": "identified"])
        Task { await Arsel.flushNow() }
        log.log("MERGE PROOF — both events sent. On the backend, contact external_id=\(id) "
            + "should now hold BOTH, and the anonymous contact should be gone.")
    }

    private func requestPermission() {
        log.log("-> requestNotificationPermission()")
        Task { @MainActor in
            let granted = await Arsel.requestNotificationPermission()
            log.log("permission -> \(granted ? "GRANTED" : "DENIED")")
            refreshDiagnostics()
        }
    }

    private func flushNow() {
        log.log("-> flushNow()")
        Task { @MainActor in
            await Arsel.flushNow()
            log.log("flushNow() returned")
            refreshDiagnostics()
        }
    }

    private func resetIdentity() {
        log.log("-> reset()")
        Arsel.reset()
        refreshDiagnostics()
    }

    private func optOut() {
        // Deliberately not behind a confirmation dialog: the point of the harness is to
        // reach this state and observe that a later registration does NOT resurrect it.
        log.log("-> optOut()")
        Arsel.optOut()
        refreshDiagnostics()
    }

    // MARK: Reads

    private func refreshDiagnostics() {
        guard let d = Arsel.diagnostics() else {
            installationId = "(SDK not initialized)"
            anonymousId = "(SDK not initialized)"
            diagnosticsText = "(SDK not initialized — check Config/*.xcconfig; the SDK "
                + "logs why it refused in the Xcode console)"
            return
        }
        installationId = d.installationId ?? "(pending)"
        anonymousId = Arsel.anonymousId ?? "(pending)"
        diagnosticsText = renderDiagnostics(d)

        // Only the fields that move on their own are worth a timeline entry; dumping the
        // whole snapshot on every poll would bury the one line that matters.
        let condensed = "diagnostics: secret=\(d.hasDeviceSecret) "
            + "asserted=\(d.hasAssertedIdentity) optedOut=\(d.optedOut) "
            + "pending=\(d.pendingRequests) "
            + "last=\(d.lastResponseCode.map(String.init) ?? "-") \(d.lastResponsePath ?? "-")"
        if condensed != lastLoggedDiagnostics {
            lastLoggedDiagnostics = condensed
            log.log(condensed)
        }
    }

    private func renderDiagnostics(_ d: ArselDiagnostics) -> String {
        """
        sdkVersion: \(d.sdkVersion)
        hasPushToken: \(d.hasPushToken)  vendor: \(d.pushVendor ?? "-")
        hasDeviceSecret: \(d.hasDeviceSecret)
        hasAssertedIdentity: \(d.hasAssertedIdentity)
        optedOut: \(d.optedOut)
        enablementStatus: \(d.enablementStatus ?? "-")
        pendingRequests: \(d.pendingRequests)
        lastResponse: \(d.lastResponseCode.map(String.init) ?? "-") \(d.lastResponsePath ?? "-")
        """
    }

    // MARK: View helpers

    private func fieldLabel(_ text: String) -> some View {
        Text(text).font(.caption.bold()).padding(.top, 4)
    }

    private func noteText(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
    }

    private func monoText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func harnessField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .disableAutocorrection(true)
            .font(.system(size: 14, design: .monospaced))
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }

    private func copyButton(_ title: String, value: String?) -> some View {
        actionButton(title) {
            guard let value, !value.isEmpty else {
                log.log("nothing to copy yet")
                return
            }
            UIPasteboard.general.string = value
            log.log("copied to pasteboard")
        }
    }
}

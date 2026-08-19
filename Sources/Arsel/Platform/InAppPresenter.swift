#if canImport(UIKit)
import Foundation
import UIKit

/// Draws an in-app message over whatever the app is currently showing.
///
/// This file is the reason the Linux CI job exists: it is the only place UIKit may appear, and
/// `Core/` is proven Foundation-only by that job compiling without it.
///
/// The message is presented in its own `UIWindow` rather than pushed into the host's view
/// hierarchy. A window can be torn down without knowing anything about the host's navigation, it
/// survives a controller being swapped underneath it, and it never mutates a view the host owns —
/// which is the class of breakage nobody ever traces back to an SDK.
final class InAppPresenter {
    private weak var core: ArselCore?
    private var window: UIWindow?
    private var shownAtMs: Int64 = 0
    private var current: InAppMessage?

    init(core: ArselCore) {
        self.core = core
    }

    /// Entry point from the core, which runs on its own serial queue.
    ///
    /// Everything below this line is main-queue only — UIKit demands it, and the hop is explicit
    /// rather than an actor annotation because `MainActor.assumeIsolated` needs iOS 17 and this
    /// package ships to 15.
    func present(_ message: InAppMessage) {
        let delay = max(0, message.delaySeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(delay)) { [weak self] in
            self?.show(message)
        }
    }

    private func show(_ message: InAppMessage) {
        // Already showing something, or the app left the foreground during the delay window.
        // Abandoned silently: no beacon and no counter, because a message nobody saw is not an
        // impression and recording one corrupts every rate in the channel.
        guard window == nil, let scene = Self.activeScene() else {
            core?.releaseInAppSlot()
            return
        }

        let host = UIWindow(windowScene: scene)
        host.windowLevel = .alert + 1
        host.backgroundColor = .clear
        let controller = InAppViewController(
            message: message,
            onButton: { [weak self] button in self?.handle(button, for: message) },
            onDismiss: { [weak self] in self?.close(reportDismiss: true) })
        host.rootViewController = controller
        host.isHidden = false

        window = host
        current = message
        shownAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Reported once the view is actually on screen, never at build time.
        core?.recordInAppImpression(message, triggerEventName: message.triggerEventName)
    }

    private func handle(_ button: InAppButton, for message: InAppMessage) {
        if button.action != InAppAction.dismiss {
            // Enqueued BEFORE any navigation: a deep link can background the app immediately, and
            // the queue is on disk so the click survives it.
            core?.recordInAppClick(message, buttonId: button.buttonId)
        }
        close(reportDismiss: button.action == InAppAction.dismiss)

        guard let value = button.value, !value.isEmpty else { return }
        switch button.action {
        case InAppAction.deepLink, InAppAction.url:
            guard let url = URL(string: value) else { return }
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        case InAppAction.customEvent:
            core?.track(value)
        default:
            break
        }
    }

    private func close(reportDismiss: Bool) {
        guard let message = current else { return }
        window?.isHidden = true
        window = nil
        current = nil
        core?.releaseInAppSlot()
        if reportDismiss {
            let visible = Int64(Date().timeIntervalSince1970 * 1000) - shownAtMs
            core?.recordInAppDismiss(message, visibleSeconds: visible / 1000)
        }
    }

    /// The scene actually in front of the user. `.foregroundActive` and not merely connected: a
    /// backgrounded or inactive scene would take the window and show it to nobody.
    private static func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

/// The message itself. Built in code rather than from a xib, so the package ships no resource
/// bundle for an integrator to carry.
private final class InAppViewController: UIViewController {
    private let message: InAppMessage
    private let onButton: (InAppButton) -> Void
    private let onDismiss: () -> Void

    init(
        message: InAppMessage,
        onButton: @escaping (InAppButton) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.onButton = onButton
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — this controller is never in a storyboard")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let scrimmed = message.layout == InAppLayout.modal || message.layout == InAppLayout.fullscreen
        view.backgroundColor = scrimmed ? UIColor.black.withAlphaComponent(Self.scrimAlpha) : UIColor.clear

        let panel = buildPanel()
        view.addSubview(panel)
        constrain(panel)

        // Dismissable by the scrim only when the author allowed a close affordance; otherwise a
        // stray tap destroys a message they meant to be deliberate.
        if scrimmed && message.showCloseButton {
            let tap = UITapGestureRecognizer(target: self, action: #selector(scrimTapped))
            view.addGestureRecognizer(tap)
        }
    }

    @objc private func scrimTapped() {
        onDismiss()
    }

    @objc private func closeTapped() {
        onDismiss()
    }

    @objc private func buttonTapped(_ sender: UIButton) {
        guard sender.tag >= 0, sender.tag < message.buttons.count else { return }
        onButton(message.buttons[sender.tag])
    }

    private func buildPanel() -> UIView {
        let panelColor = Self.color(from: message.backgroundColor) ?? .systemBackground
        let textColor = Self.color(from: message.textColor) ?? Self.contrasting(with: panelColor)

        let panel = UIView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.backgroundColor = panelColor
        panel.layer.cornerRadius = Self.cornerRadius
        panel.accessibilityViewIsModal = message.layout == InAppLayout.modal

        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = Self.spacing

        if message.layout != InAppLayout.imageOnly {
            stack.addArrangedSubview(label(message.headline, size: Self.headlineSize, weight: .semibold, color: textColor))
            if !message.body.isEmpty {
                stack.addArrangedSubview(label(message.body, size: Self.bodySize, weight: .regular, color: textColor))
            }
        }
        if !message.buttons.isEmpty {
            stack.addArrangedSubview(buttonRow())
        }

        panel.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: Self.padding),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -Self.padding),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -Self.padding),
        ])

        if message.showCloseButton {
            let close = closeButton(color: textColor)
            panel.addSubview(close)
            NSLayoutConstraint.activate([
                close.topAnchor.constraint(equalTo: panel.topAnchor),
                close.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
                close.widthAnchor.constraint(equalToConstant: Self.minTapTarget),
                close.heightAnchor.constraint(equalToConstant: Self.minTapTarget),
            ])
        }
        return panel
    }

    private func constrain(_ panel: UIView) {
        let guide = view.safeAreaLayoutGuide
        var constraints: [NSLayoutConstraint] = [
            panel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: Self.margin),
            panel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -Self.margin),
        ]
        switch message.layout {
        case InAppLayout.bannerTop:
            constraints.append(panel.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.margin))
        case InAppLayout.bannerBottom:
            constraints.append(panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.margin))
        case InAppLayout.fullscreen:
            constraints.append(panel.topAnchor.constraint(equalTo: guide.topAnchor, constant: Self.margin))
            constraints.append(panel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -Self.margin))
        default:
            constraints.append(panel.centerYAnchor.constraint(equalTo: guide.centerYAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }

    /// Text is always assigned as a value, never rendered as markup: the content is org-authored
    /// and displays inside the customer's own app.
    private func label(_ text: String, size: CGFloat, weight: UIFont.Weight, color: UIColor) -> UILabel {
        let view = UILabel()
        view.text = text
        view.textColor = color
        view.font = .systemFont(ofSize: size, weight: weight)
        view.numberOfLines = 0
        return view
    }

    private func buttonRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Self.spacing
        for (index, button) in message.buttons.enumerated() {
            let view = UIButton(type: .system)
            view.setTitle(button.label, for: .normal)
            view.tag = index
            view.addTarget(self, action: #selector(buttonTapped(_:)), for: .touchUpInside)
            view.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.minTapTarget).isActive = true
            row.addArrangedSubview(view)
        }
        return row
    }

    private func closeButton(color: UIColor) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(Self.closeGlyph, for: .normal)
        button.setTitleColor(color, for: .normal)
        button.accessibilityLabel = Self.closeLabel
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }

    private static func color(from hex: String?) -> UIColor? {
        guard var value = hex, value.hasPrefix("#") else { return nil }
        value.removeFirst()
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        return UIColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1)
    }

    /// Supplies the readable half of a colour pair when an author set only the background —
    /// otherwise a white-on-white message reports a healthy impression nobody could read.
    private static func contrasting(with background: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .label }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.6 ? .black : .white
    }

    private static let scrimAlpha: CGFloat = 0.45
    private static let cornerRadius: CGFloat = 12
    private static let padding: CGFloat = 20
    private static let margin: CGFloat = 16
    private static let spacing: CGFloat = 8

    /// Apple's minimum touch target; anything smaller fails an accessibility audit.
    private static let minTapTarget: CGFloat = 44
    private static let headlineSize: CGFloat = 18
    private static let bodySize: CGFloat = 15
    private static let closeGlyph = "\u{00D7}"
    private static let closeLabel = "Close"
}
#endif

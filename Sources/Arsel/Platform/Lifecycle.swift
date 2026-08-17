import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension Arsel {
    /// Session boundaries from UIApplication lifecycle notifications. Observing the
    /// notification names needs no UIApplication instance, so this is safe wherever
    /// UIKit merely links. On platforms without UIKit (tests, macOS CI) sessions
    /// are simply not driven automatically.
    static func attachLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { _ in
            core?.onForeground()
            // Also the natural moment to notice a Settings-app permission change.
            refreshPermissionState()
        }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { _ in
            core?.onBackground()
        }
        center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            core?.onBackground()
        }
        #endif
    }
}

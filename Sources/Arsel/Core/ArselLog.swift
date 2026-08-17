import Foundation

public enum ArselLogLevel: Int, Comparable, Sendable {
    case verbose = 0, debug, info, warn, error, none

    public static func < (lhs: ArselLogLevel, rhs: ArselLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Print-based on purpose: `os.Logger` is unavailable on Linux, and the SDK's log volume
/// at the default `.warn` level is a handful of lines per install.
struct ArselLog {
    let level: ArselLogLevel

    func d(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func i(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func w(_ message: @autoclosure () -> String) { emit(.warn, message()) }
    func e(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private func emit(_ at: ArselLogLevel, _ message: String) {
        guard at >= level, level != .none else { return }
        print("[arsel] \(message)")
    }
}

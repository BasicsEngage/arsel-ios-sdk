import Foundation

/// Emits `arsel.session_start` / `arsel.session_end` from foreground and background
/// transitions.
///
/// **No timers.** A session ends when the app has been in the background longer than
/// `sessionGapMs`, but that fact is only *discovered* on the next foreground — so the
/// end event is emitted then, backdated to the moment the app actually went away. A
/// scheduled timer would have to survive process death and iOS suspension to be
/// correct, and would fire in a process that may no longer exist.
///
/// The consequence is the standard one for mobile analytics: a user who never
/// returns never produces a `session_end`. An open-but-unclosed session beats a
/// fabricated end time.
///
/// State lives in the store rather than memory because backgrounding is exactly when
/// iOS kills the process — an in-memory `backgroundedAt` would be lost in the case
/// it exists to handle.
final class SessionTracker {
    /// 30 minutes, matching the Android and web SDKs so a "session" means the same
    /// thing on every platform.
    static let sessionGapMs: Int64 = 30 * 60 * 1000

    /// A continuously-foregrounded stretch longer than this with no recorded
    /// background can only be a process that died foregrounded. Its end was never
    /// observed, so it is dropped unclosed rather than closed with a duration
    /// spanning the dead days — the clamp against process-death inflation.
    static let maxSessionMs: Int64 = 4 * 60 * 60 * 1000

    private let store: StateStore
    private let events: EventController
    private let clock: () -> Int64

    init(store: StateStore, events: EventController, clock: @escaping () -> Int64 = nowMillis) {
        self.store = store
        self.events = events
        self.clock = clock
    }

    func onForeground() {
        let now = clock()
        let openedAt = store.current.sessionStartedAtMs
        let backgroundedAt = store.current.backgroundedAtMs

        if openedAt != 0 {
            if backgroundedAt != 0 {
                // Only a long enough absence rolls the session over; anything shorter
                // is the same session resuming, which is not an event.
                if now - backgroundedAt < Self.sessionGapMs { return }
                endSession(openedAtMs: openedAt, endedAtMs: backgroundedAt)
            } else if now - openedAt <= Self.maxSessionMs {
                return // still the same open session (re-fire, or a quick crash relaunch)
            } else {
                store.mutate { $0.sessionStartedAtMs = 0 }
            }
        }

        store.mutate {
            $0.sessionStartedAtMs = now
            $0.backgroundedAtMs = 0
        }
        events.trackReserved(EventBodies.sessionStart, timestampMs: now)
    }

    func onBackground() {
        // Recorded, not emitted: whether this is the end of a session or a
        // three-second app switch is not knowable yet.
        guard store.current.sessionStartedAtMs != 0 else { return }
        store.mutate { $0.backgroundedAtMs = clock() }
    }

    /// Backdated to when the app actually left, not to when we noticed.
    private func endSession(openedAtMs: Int64, endedAtMs: Int64) {
        events.trackReserved(
            EventBodies.sessionEnd,
            properties: ["duration_seconds": Int((endedAtMs - openedAtMs) / 1000)],
            timestampMs: endedAtMs)
        store.mutate { $0.sessionStartedAtMs = 0 }
    }
}

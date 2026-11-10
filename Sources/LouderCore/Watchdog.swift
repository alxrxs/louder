/// Decides when a running engine has stalled. The IO proc counts its callbacks; the app
/// samples that count on a timer while the device reports it's running (Core Audio idles
/// a tap's aggregate when nothing is playing). A running device that stops calling back
/// died under us: sleep, a driver reset, or a format change we weren't told about.
public struct Watchdog: Sendable {
    public enum Action: Equatable, Sendable {
        case healthy
        case restart
        /// Restarting hasn't helped; stop trying and tell the user.
        case giveUp
    }

    public let maximumRestarts: Int
    private var lastCount: UInt64?
    private var restarts = 0

    public init(maximumRestarts: Int = 3) {
        self.maximumRestarts = maximumRestarts
    }

    /// Call on every timer tick while running, with the IO proc's callback count.
    public mutating func check(callbacks: UInt64) -> Action {
        defer { lastCount = callbacks }
        guard let lastCount, callbacks == lastCount else {
            if lastCount != nil { restarts = 0 }
            return .healthy
        }
        restarts += 1
        return restarts > maximumRestarts ? .giveUp : .restart
    }

    /// Call after (re)starting, so the fresh device gets a full interval to call back.
    public mutating func engineStarted() {
        lastCount = nil
    }

    /// Call when the user turns the engine off or on, forgetting past failures.
    public mutating func reset() {
        lastCount = nil
        restarts = 0
    }
}

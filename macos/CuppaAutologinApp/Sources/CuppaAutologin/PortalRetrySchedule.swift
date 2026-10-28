import Foundation

/// Mirrors CuppaEngine.once's bounded fast-retry loop. While a single
/// launchd invocation is actively signing in, the engine re-probes every ~6s
/// rather than waiting for the next scheduled tick (30s by default). The UI
/// must describe that fast cadence during an active attempt, not the launchd
/// interval — otherwise it shows a misleading "retry in 30s" while the engine
/// is really retrying in a few seconds.
enum FastRetry {
    static let intervalSeconds: TimeInterval = 6
    static let budgetSeconds: TimeInterval = 30

    /// A check newer than this means the engine is still inside its fast-retry
    /// loop (interval + typical probe work + slack). Older than this while
    /// still CAPTIVE means the loop's budget was spent and we're idling until
    /// the next launchd tick.
    static let activeWindowSeconds: TimeInterval = 12

    /// True while the engine is actively fast-retrying this network.
    static func isActivelyRetrying(lastCheck: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastCheck) <= activeWindowSeconds
    }

    /// Seconds until the next fast-retry probe (0 = due now / in flight).
    static func secondsUntilNextTry(lastCheck: Date, now: Date) -> Int {
        max(0, Int(ceil(intervalSeconds - now.timeIntervalSince(lastCheck))))
    }
}

struct PortalRetrySchedule {
    let interval: MonitoringInterval

    func remainingSeconds(
        after attemptStartedAt: Date,
        now: Date = Date()
    ) -> Int {
        interval.countdownSeconds(
            lastCheck: attemptStartedAt,
            now: now
        )
    }

    func isReady(
        after attemptStartedAt: Date,
        now: Date = Date()
    ) -> Bool {
        remainingSeconds(after: attemptStartedAt, now: now) == 0
    }
}

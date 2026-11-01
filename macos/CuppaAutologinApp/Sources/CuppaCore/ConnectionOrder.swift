import Foundation

/// One visit's connection accounting. Portal renewals are refills, not new orders.
/// This is presentation history only; it never authorizes access or login credit.
public struct ConnectionOrder: Codable, Equatable, Sendable {
    public let startedAt: TimeInterval
    public private(set) var onlineSince: TimeInterval?
    public private(set) var onlineSeconds: TimeInterval = 0
    public private(set) var previousCupSeconds: TimeInterval = 0
    public private(set) var refillCount: Int = 0
    public private(set) var refills: [ConnectionRefill] = []

    public init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        onlineSince = startedAt
    }

    public func connectedSeconds(at now: TimeInterval) -> TimeInterval {
        onlineSeconds + (onlineSince.map { max(0, now - $0) } ?? 0)
    }

    public mutating func interrupt(at now: TimeInterval) {
        guard let since = onlineSince, now.isFinite else { return }
        previousCupSeconds = max(0, now - since)
        onlineSeconds += previousCupSeconds
        onlineSince = nil
    }

    @discardableResult
    public mutating func reconnect(at now: TimeInterval, automatic: Bool) -> ConnectionRefill? {
        guard onlineSince == nil, now.isFinite, now >= startedAt else { return nil }
        refillCount += 1
        let refill = ConnectionRefill(number: refillCount, timestamp: now,
            previousCupSeconds: previousCupSeconds, automatic: automatic)
        refills.append(refill)
        // Keep the lifetime count and total even when old receipt rows are pruned.
        refills = Array(refills.suffix(64))
        onlineSince = now
        return refill
    }
}

public struct ConnectionRefill: Codable, Equatable, Sendable, Identifiable {
    public let number: Int
    public let timestamp: TimeInterval
    public let previousCupSeconds: TimeInterval
    public let automatic: Bool
    public var id: Int { number }
}

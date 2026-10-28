import Foundation

enum PortalLoadRetryPolicy {
    static func shouldRetry(code: Int, retries: Int, actions: Int,
                            pendingSubmission: Bool, remaining: TimeInterval) -> Bool {
        [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut,
         NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost].contains(code)
            && retries < 2 && actions == 0 && !pendingSubmission && remaining > 4
    }
}

struct PortalDiagnosticEvent: Codable, Equatable {
    let time: TimeInterval
    let title: String
}

struct PortalDiagnostics: Codable, Equatable {
    var format = 1
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var phase: String
    var title: String
    var actions = 0
    var navigations = 0
    var reasoningRequests = 0
    var terminal = false
    var reason: String?
    var detail: String?
    var failureCode: Int?
    var events: [PortalDiagnosticEvent] = []

    enum CodingKeys: String, CodingKey {
        case format, phase, title, actions, navigations, terminal, reason, detail, events
        case startedAt = "started_at", updatedAt = "updated_at"
        case reasoningRequests = "reasoning_requests", failureCode = "failure_code"
    }

    static func load(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url), data.count <= 64_000,
              let record = try? JSONDecoder().decode(Self.self, from: data),
              record.format == 1, record.events.count <= 32,
              record.title.count <= 160, record.phase.count <= 60, (record.detail?.count ?? 0) <= 1000,
              record.startedAt.isFinite, record.updatedAt.isFinite,
              record.updatedAt >= record.startedAt else { return nil }
        return record
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func isActive(at date: Date) -> Bool {
        // HTTP discovery can precede the browser's own 90-second budget.
        // Recent progress remains live even when discovery began earlier.
        !terminal && date.timeIntervalSince1970 - updatedAt < 90
    }

    func elapsed(at date: Date) -> Int {
        Int(max(0, min(600, (terminal ? updatedAt : date.timeIntervalSince1970) - startedAt)))
    }

    mutating func advance(phase: String, title: String, terminal: Bool = false,
                          reason: String? = nil, now: Date = Date()) {
        self.phase = phase
        self.title = title
        self.terminal = terminal
        self.reason = reason
        self.detail = nil
        updatedAt = now.timeIntervalSince1970
        if events.last?.title != title {
            events.append(PortalDiagnosticEvent(time: updatedAt, title: title))
            events = Array(events.suffix(32))
        }
    }
}

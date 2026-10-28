import Foundation

enum MonitoringInterval: Int, CaseIterable, Identifiable {
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .tenSeconds: "10 seconds"
        case .thirtySeconds: "30 seconds"
        case .oneMinute: "1 minute"
        case .twoMinutes: "2 minutes"
        case .fiveMinutes: "5 minutes"
        }
    }

    var energyNote: String? {
        self == .tenSeconds ? "Higher battery and network activity" : nil
    }

    func countdownSeconds(
        lastCheck: Date,
        now: Date = Date()
    ) -> Int {
        max(
            0,
            Int(
                ceil(
                    lastCheck.addingTimeInterval(
                        TimeInterval(rawValue)
                    ).timeIntervalSince(now)
                )
            )
        )
    }
}

struct AgentPreferences: Equatable {
    var interval: MonitoringInterval
    var ignorePersonalHotspots: Bool
    var resetWiFiAfterFailures: Bool
    var automaticSpeedTests: Bool = true
}

enum AgentPreferencesStore {
    private static let intervalKey = "monitoringIntervalSeconds"
    private static let monitoringEnabledKey = "monitoringEnabled"
    private static let automaticSpeedTestsKey = "automaticSpeedTestsEnabled"

    static func load(identity: FakeIdentity, defaults: UserDefaults = .standard) -> AgentPreferences {
        let stored = defaults.integer(forKey: intervalKey)
        let interval = MonitoringInterval(rawValue: stored) ?? .thirtySeconds
        return AgentPreferences(
            interval: interval,
            ignorePersonalHotspots: identity.ignoreHotspots,
            resetWiFiAfterFailures: identity.reassociationEnabled,
            automaticSpeedTests: defaults.object(forKey: automaticSpeedTestsKey) == nil
                ? true : defaults.bool(forKey: automaticSpeedTestsKey)
        )
    }

    static func save(_ preferences: AgentPreferences, defaults: UserDefaults = .standard) {
        defaults.set(
            preferences.interval.rawValue,
            forKey: intervalKey
        )
        defaults.set(preferences.automaticSpeedTests, forKey: automaticSpeedTestsKey)
    }

    static var monitoringEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: monitoringEnabledKey)
                    != nil
            else {
                return true
            }
            return UserDefaults.standard.bool(forKey: monitoringEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: monitoringEnabledKey)
        }
    }
}

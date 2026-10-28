import Foundation

enum NetworkNameCache {
    static func key(for gateway: String) -> String { "confirmedSSID.\(gateway)" }

    static func canStore(_ ssid: String, state: AgentState) -> Bool {
        // CoreWLAN can show the new SSID while the periodically refreshed
        // engine still names the previous gateway. Do not join those readings.
        !ssid.isEmpty && state.ssid == ssid && state.gatewayMac != nil
            && !GatewayMAC.isShared(state.gatewayMac)
    }
}

struct NetworkNameRefreshDelay {
    private(set) var gateway: String?
    private(set) var until: Date?

    mutating func noteGatewayChange(
        to gateway: String?,
        now: Date = Date(),
        delay: TimeInterval = 3
    ) {
        self.gateway = gateway
        until = gateway == nil ? nil : now.addingTimeInterval(delay)
    }

    mutating func shouldDefer(
        gateway currentGateway: String?,
        now: Date = Date()
    ) -> Bool {
        guard gateway == currentGateway, let until else {
            gateway = nil
            self.until = nil
            return false
        }
        guard now < until else {
            gateway = nil
            self.until = nil
            return false
        }
        return true
    }
}

struct CaptivePortalDismissalGate {
    private(set) var handledCheckTimestamp: TimeInterval?

    mutating func shouldDismiss(
        previous: AgentState,
        refreshed: AgentState,
        now: Date = Date(),
        maxCheckAge: TimeInterval = 45
    ) -> Bool {
        guard refreshed.lastResult == "ONLINE",
              let checkTimestamp = refreshed.lastCheckTimestamp,
              let gateway = refreshed.gatewayMac,
              previous.gatewayMac == nil || previous.gatewayMac == gateway,
              handledCheckTimestamp != checkTimestamp
        else {
            return false
        }
        // A fresh engine probe is sufficient even when the grant arrived after
        // an ambiguous submission. Retry on later probes for a late WebSheet.
        let age = now.timeIntervalSince1970 - checkTimestamp
        guard age >= -5, age <= maxCheckAge
        else {
            return false
        }
        handledCheckTimestamp = checkTimestamp
        return true
    }
}

struct NetworkDiagnostic: Codable, Equatable {
    let reason: String
    let title: String
    let detail: String
    let checks: String
    let repeated: Bool
    let addressAssigned: Bool
    let consecutiveChecks: Int
    let checkedAt: TimeInterval

    enum CodingKeys: String, CodingKey {
        case reason, title, detail, checks, repeated
        case addressAssigned = "address_assigned", consecutiveChecks = "consecutive_checks"
        case checkedAt = "checked_at"
    }
}

struct AgentState: Codable, Equatable {
    var ssid: String?
    var venue: String?
    var gatewayMac: String?
    var portalDomain: String?
    var dhcpDomain: String?
    var lastResult: String
    var lastCheckTimestamp: TimeInterval?
    var lastConnectionTimestamp: TimeInterval?
    var lastLoginTimestamp: TimeInterval?
    var lastLoginGatewayMac: String?
    var consecutiveFailures: Int
    var lastReassociationTimestamp: TimeInterval?
    var networkDiagnostic: NetworkDiagnostic? = nil

    enum CodingKeys: String, CodingKey {
        case ssid
        case venue
        case gatewayMac = "gateway_mac"
        case portalDomain = "portal_domain"
        case dhcpDomain = "dhcp_domain"
        case lastResult = "last_result"
        case lastCheckTimestamp = "last_check_ts"
        case lastConnectionTimestamp = "last_connection_ts"
        case lastLoginTimestamp = "last_login_ts"
        case lastLoginGatewayMac = "last_login_gateway_mac"
        case consecutiveFailures = "consecutive_failures"
        case lastReassociationTimestamp = "last_reassoc_ts"
        case networkDiagnostic = "network_diagnostic"
    }

    static let unknown = AgentState(
        ssid: nil,
        venue: nil,
        gatewayMac: nil,
        portalDomain: nil,
        dhcpDomain: nil,
        lastResult: "UNKNOWN",
        lastCheckTimestamp: nil,
        lastConnectionTimestamp: nil,
        lastLoginTimestamp: nil,
        lastLoginGatewayMac: nil,
        consecutiveFailures: 0,
        lastReassociationTimestamp: nil
    )

    var statusTitle: String {
        switch lastResult {
        case "ONLINE": "Online"
        case "CAPTIVE":
            consecutiveFailures > 0 ? "Sign-in failed" : "Signing in"
        case "UNSUPPORTED": "Needs verification"
        case "IGNORED": "Dormant"
        case "NO_NETWORK":
            networkDiagnostic?.reason == "proxy_interference" ? "Connection unverified" :
            networkDiagnostic?.repeated == true && networkDiagnostic?.reason == "network_path_unavailable"
                ? "Network problem" : networkDiagnostic?.addressAssigned == true ? "No internet access" : "No network"
        default: "Waiting for status"
        }
    }

}

enum AgentStateLoader {
    static func decode(_ data: Data) throws -> AgentState {
        try JSONDecoder().decode(AgentState.self, from: data)
    }

    static func load(from url: URL) -> AgentState {
        guard let data = try? Data(contentsOf: url),
              let state = try? decode(data)
        else {
            return .unknown
        }
        return state
    }
}

enum ConnectionDurationFormatter {
    static func string(from start: Date, to end: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return "\(hours)h \(minutes)m \(remainder)s"
    }
}

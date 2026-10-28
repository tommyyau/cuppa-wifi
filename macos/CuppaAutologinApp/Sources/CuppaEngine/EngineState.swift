import CuppaCore
import Foundation

/// Lossless, forward-compatible v1 state record. Typed accessors keep policy out of JSON plumbing.
public struct EngineState {
    public var fields: [String: Any]
    public init(fields: [String: Any] = [:]) {
        self.fields = fields
        self.fields["engine_version"] = 2
        if fields["last_result"] == nil { self.fields["last_result"] = "UNKNOWN" }
        if fields["consecutive_failures"] == nil { self.fields["consecutive_failures"] = 0 }
    }
    public var result: String {
        get { fields["last_result"] as? String ?? "UNKNOWN" }
        set { fields["last_result"] = newValue }
    }
    public var failures: Int {
        get { fields["consecutive_failures"] as? Int ?? 0 }
        set { fields["consecutive_failures"] = newValue }
    }
    public var network: NetworkSnapshot {
        NetworkSnapshot(
            gatewayMAC: fields["gateway_mac"] as? String, ssid: fields["ssid"] as? String,
            dhcpDomain: fields["dhcp_domain"] as? String)
    }
    public var fingerprint: String? {
        NetworkIdentity.fingerprint(network, portalDomain: fields["portal_domain"] as? String)
    }
    public mutating func begin(network: NetworkSnapshot, now: TimeInterval) -> Bool {
        let changed = NetworkIdentity.changed(from: self.network, to: network)
        if changed {
            for key in [
                "ssid", "venue", "portal_domain", "last_connection_ts", "last_login_ts",
                "last_login_gateway_mac", "last_notified_event", "network_diagnostic",
            ] { fields.removeValue(forKey: key) }
            failures = 0
            result = "UNKNOWN"
        }
        if let mac = network.gatewayMAC {
            if fields["last_login_ts"] != nil {
                if fields["last_login_gateway_mac"] == nil && !changed {
                    fields["last_login_gateway_mac"] = mac
                } else if fields["last_login_gateway_mac"] as? String != mac {
                    fields.removeValue(forKey: "last_login_ts")
                    fields.removeValue(forKey: "last_login_gateway_mac")
                }
            }
            fields["gateway_mac"] = mac
        }
        fields["dhcp_domain"] = network.dhcpDomain
        fields["last_check_ts"] = now
        return changed
    }
    public mutating func markOnline(
        network: NetworkSnapshot, now: TimeInterval, automatedLogin: Bool,
        newConnection: Bool = false
    ) {
        let previous = result
        result = "ONLINE"
        failures = 0
        fields["last_check_ts"] = now
        fields.removeValue(forKey: "network_diagnostic")
        fields.removeValue(forKey: "last_notified_event")
        if let ssid = network.ssid { fields["ssid"] = ssid }
        if let mac = network.gatewayMAC { fields["gateway_mac"] = mac }
        if automatedLogin || newConnection || fields["last_connection_ts"] == nil
            || ["UNKNOWN", "NO_NETWORK"].contains(previous)
        {
            fields["last_connection_ts"] = now
        }
        if automatedLogin {
            fields["last_login_ts"] = now
            fields["last_login_gateway_mac"] = network.gatewayMAC
            fields["gateway_mac"] = network.gatewayMAC
        }
    }
    public static func load(_ paths: EnginePaths) -> Self {
        .init(fields: PrivateFile.object(at: paths.state) ?? [:])
    }
    public func save(_ paths: EnginePaths) throws {
        try PrivateFile.writeJSON(fields, to: paths.state)
    }
}

import Foundation

/// Provider resolution uses domain first, then SSID, then an exact gateway MAC.
/// Network naming alone never authorizes sending Persona to a provider endpoint.
public struct PortalRegistry: Sendable {
    public struct Entry: Sendable {
        public let name: String
        public let provider: String
        public let domainPattern: String?
        public let ssidPattern: String?
        public let gatewayMAC: String?
        public init(
            name: String, provider: String, domainPattern: String? = nil,
            ssidPattern: String? = nil, gatewayMAC: String? = nil
        ) {
            self.name = name
            self.provider = provider
            self.domainPattern = domainPattern
            self.ssidPattern = ssidPattern
            self.gatewayMAC = gatewayMAC
        }
    }
    public struct Resolution: Equatable, Sendable {
        public let name: String
        public let provider: String
    }
    public let entries: [Entry]
    public init(entries: [Entry]? = nil) {
        self.entries =
            entries ?? [
                Entry(
                    name: "Fydelia", provider: "fydelia", domainPattern: #"(?:^|\.)fydelia\.com$"#),
                Entry(
                    name: "BT Wi-Fi", provider: "bt",
                    domainPattern: #"(?:^|\.)(?:portal|www|reg)\.btwifi\.com$"#),
                Entry(
                    name: "Wireless Social", provider: "wireless-social",
                    domainPattern: #"(?:^|\.)wifi\.wireless-social\.com$"#,
                    ssidPattern: #"(?:tenpin|wireless[ _-]?social)"#),
                Entry(name: "Tim Hortons", provider: "generic", ssidPattern: #"tim ?hortons?"#),
            ]
    }
    public func resolve(domain: String?, ssid: String?, gatewayMAC: String?) -> Resolution {
        for entry in entries {
            if let pattern = entry.domainPattern, let domain, matches(pattern, domain) {
                return Resolution(name: entry.name, provider: entry.provider)
            }
        }
        for entry in entries {
            if let pattern = entry.ssidPattern, let ssid, matches(pattern, ssid) {
                return Resolution(name: entry.name, provider: entry.provider)
            }
        }
        for entry in entries {
            if let mac = entry.gatewayMAC, let gatewayMAC,
                mac.lowercased() == gatewayMAC.lowercased()
            {
                return Resolution(name: entry.name, provider: entry.provider)
            }
        }
        return Resolution(
            name: ssid.flatMap { $0.isEmpty ? nil : $0 }
                ?? domain.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown", provider: "generic")
    }
}

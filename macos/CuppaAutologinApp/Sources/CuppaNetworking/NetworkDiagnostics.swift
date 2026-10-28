import CoreFoundation
import CuppaCore
import Foundation

public struct NetworkDiagnosis: @unchecked Sendable {
    public var evidence: [String: Any]
    public var portalURL: URL?
    public init(evidence: [String: Any], portalURL: URL? = nil) {
        self.evidence = evidence
        self.portalURL = portalURL
    }
}
public struct NetworkDiagnostics: Sendable {
    let client: any HTTPClient
    let network: NetworkSnapshot
    let commands: any SystemCommandRunning
    public init(
        client: any HTTPClient, network: NetworkSnapshot,
        commands: any SystemCommandRunning = NativeSystemCommands()
    ) {
        self.client = client
        self.network = network
        self.commands = commands
    }
    public static func portalRedirect(from url: URL, location: String?, gateway: String?) -> URL? {
        guard let location, location.utf8.count <= 8192,
            !location.unicodeScalars.contains(where: { $0.value < 32 }),
            let target = PortalRequestURL.url(location, relativeTo: url)?.absoluteURL,
            ["http", "https"].contains(target.scheme), let host = target.host?.lowercased(),
            target.user == nil, target.password == nil,
            target.port == nil || [80, 443, 1000].contains(target.port!), host != "localhost",
            !["1.1.1.1", "one.one.one.one", "cloudflare.com", "www.cloudflare.com"].contains(host)
        else { return nil }
        if ScopedDNSResolver.isIPAddress(host), !BrowserRelay.isGlobalAddress(host), host != gateway
        {
            return nil
        }
        if url.absoluteString != "http://1.1.1.1/"
            && !["captive", "portal", "splash", "hotspot", "fgtauth", "guest"].contains(where: {
                target.path.lowercased().contains($0)
            })
        {
            return nil
        }
        return target
    }
    public static func probeErrors(_ errors: [String]) -> [String] {
        errors.prefix(4).compactMap { value in
            guard let source = value.split(separator: ":", maxSplits: 1).first,
                ["apple", "gstatic"].contains(source)
            else { return nil }
            let lowered = value.lowercased()
            let category: String
            if value == "\(source):proxy_detected" {
                category = "proxy_detected"
            } else if lowered.contains("dns") || lowered.contains("nodename")
                || lowered.contains("name or service")
            {
                category =
                    lowered.contains("timeout") || lowered.contains("timed out")
                    ? "dns_timeout" : "dns_failed"
            } else if lowered.contains("permission") || lowered.contains("not permitted") {
                category = "permission_denied"
            } else if lowered.contains("timeout") || lowered.contains("timed out") {
                category = "request_timeout"
            } else if lowered.contains("unreachable") || lowered.contains("no route") {
                category = "unreachable"
            } else {
                category = "request_failed"
            }
            return "\(source):\(category)"
        }
    }
    public func diagnose(
        errors: [String] = [], progress: (@Sendable (String, String) -> Void)? = nil
    ) async -> NetworkDiagnosis {
        var evidence: [String: Any] = [
            "reason": "wifi_not_connected",
            "interface": network.interface.map { $0 as Any } ?? NSNull(), "address_assigned": false,
            "gateway_present": false,
            "gateway_ping": "not_checked", "gateway_http": ["result": "not_checked"],
            "direct_http": ["result": "not_checked"], "probe_errors": Self.probeErrors(errors),
            "macos_stage": "unknown",
        ]
        if let stage = network.captiveStage?.lowercased(),
            ["evaluate", "websheet", "authenticated", "unknown"].contains(stage)
        {
            evidence["macos_stage"] = stage
        }
        guard let interface = network.interface,
            interface.range(of: #"^[a-zA-Z][a-zA-Z0-9]{0,15}$"#, options: .regularExpression) != nil
        else { return NetworkDiagnosis(evidence: evidence) }
        progress?(
            "Checking the Wi-Fi address",
            "Internet probes failed. Checking whether Wi-Fi received a usable address.")
        let output = await commands.run(
            "/usr/sbin/ipconfig", arguments: ["getifaddr", interface], timeout: 3)
        let address = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0, !output.timedOut, ScopedDNSResolver.isIPAddress(address),
            !address.hasPrefix("169.254."), !address.lowercased().hasPrefix("fe80:"),
            address != "0.0.0.0", address != "::"
        else {
            evidence["reason"] = "address_unavailable"
            return NetworkDiagnosis(evidence: evidence)
        }
        evidence["address_assigned"] = true
        if (evidence["probe_errors"] as? [String] ?? []).contains(where: {
            $0.hasSuffix(":proxy_detected")
        }) {
            evidence["reason"] = "proxy_interference"
            return NetworkDiagnosis(evidence: evidence)
        }
        guard let gateway = network.gatewayIP, ScopedDNSResolver.isIPAddress(gateway),
            !gateway.contains(":"), !gateway.hasPrefix("127."), gateway != "0.0.0.0"
        else {
            evidence["reason"] = "gateway_unavailable"
            return NetworkDiagnosis(evidence: evidence)
        }
        evidence["gateway_present"] = true
        progress?(
            "Checking the Wi-Fi gateway",
            "Testing the local router. A missing ping reply alone does not prove a fault.")
        let ping = await commands.run(
            "/sbin/ping",
            arguments: ["-b", interface, "-c", "1", "-W", "1000", "-t", "2", gateway], timeout: 3)
        evidence["gateway_ping"] =
            ping.status == 0 && !ping.timedOut
            ? "reply" : (ping.timedOut || ping.status == 2 ? "no_reply" : "unavailable")
        func http(_ url: URL) async -> ([String: Any], URL?) {
            do {
                let response = try await client.send(
                    HTTPRequest(
                        url: url, headers: ["Cookie": ""], timeout: 2, followRedirects: false,
                        maximumBodyBytes: 0))
                let portal =
                    [301, 302, 303, 307, 308].contains(response.status)
                    ? Self.portalRedirect(
                        from: url, location: response.header("location"), gateway: gateway) : nil
                return (
                    ["result": "response", "status": response.status, "connected": true], portal
                )
            } catch {
                let category = ConnectivityProbe.errorCategory(error)
                return (
                    [
                        "result": category == "permission_denied"
                            ? category : category == "request_timeout" ? "timeout" : "unreachable",
                        "connected": (error as? HTTPTransportError)?.connected ?? false,
                    ], nil
                )
            }
        }
        progress?(
            "Looking for a portal without DNS",
            "Checking the gateway and a direct IP address for a captive redirect. No form has been submitted."
        )
        let gatewayResult = await http(URL(string: "http://\(gateway)/")!)
        let directResult = await http(URL(string: "http://1.1.1.1/")!)
        evidence["gateway_http"] = gatewayResult.0
        evidence["direct_http"] = directResult.0
        let portal = directResult.1 ?? gatewayResult.1
        if portal != nil {
            evidence["reason"] = "portal_discovered"
        } else if [gatewayResult.0, directResult.0].contains(where: {
            $0["result"] as? String == "permission_denied"
        }) {
            evidence["reason"] = "network_permission_denied"
        } else if directResult.0["result"] as? String == "response"
            || directResult.0["connected"] as? Bool == true
        {
            evidence["reason"] = "dns_or_probe_failure"
        } else if evidence["gateway_ping"] as? String == "reply"
            || gatewayResult.0["result"] as? String == "response"
            || gatewayResult.0["connected"] as? Bool == true
        {
            evidence["reason"] = "upstream_unavailable"
        } else {
            evidence["reason"] = "network_path_unavailable"
        }
        return NetworkDiagnosis(evidence: evidence, portalURL: portal)
    }
    public static func record(
        _ diagnosis: NetworkDiagnosis, previous: [String: Any], fingerprint: String,
        now: TimeInterval
    ) -> [String: Any] {
        var evidence = diagnosis.evidence
        func number(_ key: String, _ fallback: Double) -> Double {
            guard let number = previous[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
            else { return fallback }
            let value = number.doubleValue
            return value
        }
        let age = now - number("checked_at", 0)
        let same =
            !fingerprint.isEmpty && fingerprint == previous["fingerprint"] as? String
            && evidence["reason"] as? String == previous["reason"] as? String && age >= 0
            && age <= 180
        let first = same ? min(now, number("first_seen_at", now)) : now
        let count =
            same ? min(100, max(1, Int(min(99, max(0, number("consecutive_checks", 0)))) + 1)) : 1
        evidence["format"] = 1
        evidence["checked_at"] = now
        evidence["first_seen_at"] = first
        evidence["fingerprint"] = fingerprint
        evidence["consecutive_checks"] = count
        evidence["repeated"] = count >= 2 && now - first >= 15
        let text = summary(evidence)
        evidence["title"] = text.0
        evidence["detail"] = text.1
        func http(_ key: String) -> String {
            let item = evidence[key] as? [String: Any] ?? [:]
            return (item["result"] as? String ?? "not_checked")
                + (item["connected"] as? Bool == true ? " (TCP connected)" : "")
        }
        evidence["checks"] =
            "address=\(evidence["address_assigned"] as? Bool == true ? "assigned" : "unavailable"); gateway_ping=\(evidence["gateway_ping"] as? String ?? "not_checked"); gateway_http=\(http("gateway_http")); direct_http=\(http("direct_http")); probes=\((evidence["probe_errors"] as? [String] ?? []).joined(separator: ",")); macos=\(evidence["macos_stage"] as? String ?? "unknown")"
        return evidence
    }
    public static func summary(_ evidence: [String: Any]) -> (String, String) {
        switch evidence["reason"] as? String {
        case "wifi_not_connected":
            return ("Wi-Fi is not connected", "Join a Wi-Fi network, then check again.")
        case "address_unavailable":
            return (
                "Wi-Fi address not ready",
                "No usable IPv4 address was available. Waiting for network setup; IPv6-only access is not ruled out."
            )
        case "gateway_unavailable":
            return (
                "Wi-Fi gateway not ready",
                "No usable IPv4 gateway was available. Waiting for network setup."
            )
        case "portal_discovered":
            return (
                "Found a portal without DNS",
                "A direct HTTP request found a captive redirect. Continuing automatic sign-in."
            )
        case "proxy_interference":
            return (
                "Direct Wi-Fi check blocked by a proxy",
                "macOS routed a connectivity check through a proxy, which cannot verify this Wi-Fi network. Private Relay or another proxy may be active. You can turn off Limit IP Address Tracking in this network’s Wi-Fi details and check again; this reduces Private Relay protection on this network. Cuppa Wi-Fi does not change that setting."
            )
        case "network_permission_denied":
            return (
                "macOS blocked the network check",
                "The operating system denied a network request. Check Cuppa Wi-Fi’s network permissions. These checks cannot establish whether the Wi-Fi is faulty."
            )
        case "dns_or_probe_failure":
            return (
                "Network responds; internet unverified",
                "Direct HTTP responded, but connectivity probes failed. DNS or filtering may be blocking access; no portal was identified."
            )
        case "upstream_unavailable":
            return (
                "Gateway responds; internet unavailable",
                "The local gateway responded, but external checks failed and no portal was found. The network may have an upstream fault or be filtering access."
            )
        default:
            return evidence["repeated"] as? Bool == true
                ? (
                    "Likely network problem",
                    "Repeated gateway and external checks received no usable response. No portal is reachable for automatic sign-in. Try another network or ask the venue; filtering can cause the same symptoms."
                )
                : (
                    "Wi-Fi joined; access unavailable",
                    "Gateway and external checks received no usable response. No portal was found. Monitoring will retry before treating this as a persistent network problem."
                )
        }
    }
}

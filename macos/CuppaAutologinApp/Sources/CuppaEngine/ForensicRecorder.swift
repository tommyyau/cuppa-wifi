import CuppaCore
import CuppaNetworking
import Foundation

/// Bounded, read-only diagnostics. Raw artifacts remain private, and never count
/// as connectivity proof or authorize a portal submission.
public struct ForensicRecorder: Sendable {
    public let paths: EnginePaths
    public let commands: any SystemCommandRunning
    private let resolveHost: (@Sendable (String, Date) async throws -> [String])?
    public init(
        paths: EnginePaths, commands: any SystemCommandRunning = NativeSystemCommands(),
        resolveHost: (@Sendable (String, Date) async throws -> [String])? = nil
    ) {
        self.paths = paths
        self.commands = commands
        self.resolveHost = resolveHost
    }
    public func shouldRun(fingerprint: String, now: TimeInterval = Date().timeIntervalSince1970)
        -> Bool
    {
        guard !fingerprint.isEmpty else { return false }
        let marker = paths.forensics.appendingPathComponent(EvidenceStore.safeKey(fingerprint))
            .appendingPathComponent("last_sweep_ts")
        guard let text = try? String(contentsOf: marker, encoding: .utf8),
            let previous = Double(text)
        else { return true }
        return now >= previous && now - previous >= 900
    }
    public func run(
        network: NetworkSnapshot, client: any HTTPClient, portalURL: URL? = nil,
        reason: String? = nil,
        trigger: String = "login_failure", now: TimeInterval = Date().timeIntervalSince1970
    ) async -> URL? {
        let fingerprint =
            NetworkIdentity.fingerprint(network, portalDomain: portalURL?.host) ?? "unknown"
        let parent = paths.forensics.appendingPathComponent(EvidenceStore.safeKey(fingerprint))
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let timestamp = formatter.string(from: Date(timeIntervalSince1970: now))
        let directory = parent.appendingPathComponent(timestamp)
        let deadline = Date().addingTimeInterval(45)
        do {
            try PrivateFile.directory(paths.forensics)
            try PrivateFile.directory(parent)
            try PrivateFile.directory(directory)
            var environment: [String: Any] = [
                "captured_at": timestamp, "trigger": trigger, "fingerprint": fingerprint,
            ]
            environment["interface"] = network.interface
            environment["gateway_ip"] = network.gatewayIP
            environment["gateway_mac"] = network.gatewayMAC
            environment["ssid"] = network.ssid
            environment["portal_url_hint"] = portalURL?.absoluteString
            environment["failure_reason"] = reason
            try PrivateFile.writeJSON(
                environment, to: directory.appendingPathComponent("environment.json"))
            var inspections: [(String, String, [String])] = [
                ("route", "/sbin/route", ["-n", "get", "default"]),
                ("dns", "/usr/sbin/scutil", ["--dns"]),
                ("proxy", "/usr/sbin/scutil", ["--proxy"]),
                ("interfaces", "/sbin/ifconfig", ["-a"]), ("arp", "/usr/sbin/arp", ["-an"]),
            ]
            if let interface = network.interface,
                interface.range(of: "^[a-zA-Z][a-zA-Z0-9]{0,15}$", options: .regularExpression)
                    != nil
            {
                inspections += [
                    ("dhcp", "/usr/sbin/ipconfig", ["getpacket", interface]),
                    (
                        "route_scoped", "/sbin/route",
                        ["-n", "get", "-ifscope", interface, "default"]
                    ),
                ]
            }
            var errors: [String] = []
            for (name, executable, args) in inspections {
                guard !Task.isCancelled, deadline > Date() else {
                    errors.append("diagnostic_deadline")
                    break
                }
                let result = await commands.run(
                    executable, arguments: args, timeout: min(3, deadline.timeIntervalSinceNow))
                try PrivateFile.write(
                    Data(String(result.text.prefix(256_000)).utf8),
                    to: directory.appendingPathComponent("commands/\(name).txt"))
                if result.status != 0 || result.timedOut {
                    errors.append(name + ":command_unavailable")
                }
            }
            let query: DNSQueryFunction? = resolveHost.map { resolve in
                { @Sendable _, _, host, _, deadline in try await resolve(host, deadline) }
            }
            let resolver = ScopedDNSResolver(
                network: network, commands: commands,
                servers: query == nil ? nil : [], queryServer: query)
            let matrix = await resolver.diagnosticMatrix(
                hosts: [portalURL?.host].compactMap { $0 },
                deadline: min(deadline, Date().addingTimeInterval(12)))
            try PrivateFile.writeJSON(
                matrix.json, to: directory.appendingPathComponent("dns_matrix.json"))
            var targets = [
                ("raw_ip", URL(string: "http://1.1.1.1/")!),
                ("apple_probe", ConnectivityProbe.appleURL),
            ]
            if let url = NativeNetworkRecovery.gatewayURL(network.gatewayIP) {
                targets.insert(("gateway", url), at: 1)
            }
            var probes: [String: Any] = [:]
            var discovered: URL?
            for (label, url) in targets {
                guard deadline > Date(), !Task.isCancelled else { break }
                do {
                    let response = try await client.send(
                        HTTPRequest(
                            url: url, timeout: min(3, deadline.timeIntervalSinceNow),
                            followRedirects: false, maximumBodyBytes: 524_288))
                    var item: [String: Any] = [
                        "url": url.absoluteString, "status": response.status,
                        "analysis": Self.analyze(response.text),
                    ]
                    if let location = response.header("location"),
                        let target = PortalRequestURL.url(location, relativeTo: url)?.absoluteURL,
                        ["http", "https"].contains(target.scheme ?? "")
                    {
                        item["location"] = target.absoluteString
                        if target.host != url.host || label == "gateway" {
                            discovered = discovered ?? target
                        }
                    }
                    probes[label] = item
                    try PrivateFile.write(
                        response.body,
                        to: directory.appendingPathComponent("http/\(label)_body.html"))
                } catch {
                    probes[label] = ["url": url.absoluteString, "error": "transport_unavailable"]
                }
            }
            try PrivateFile.writeJSON(
                probes, to: directory.appendingPathComponent("http_probes.json"))
            var current = portalURL ?? discovered
            var chain: [[String: Any]] = []
            var finalURL: URL?
            var finalBody = ""
            for sequence in 1...6 {
                guard let url = current, deadline > Date(), !Task.isCancelled else { break }
                do {
                    let response = try await client.send(
                        HTTPRequest(
                            url: url, timeout: min(4, deadline.timeIntervalSinceNow),
                            followRedirects: false, maximumBodyBytes: 524_288))
                    var item: [String: Any] = [
                        "seq": sequence, "url": url.absoluteString, "status": response.status,
                        "analysis": Self.analyze(response.text),
                    ]
                    try PrivateFile.write(
                        response.body,
                        to: directory.appendingPathComponent(
                            String(format: "portal/%02d_body.html", sequence)))
                    let scriptNext = Self.scriptRedirect(response.text, base: url)
                    let next =
                        response.header("location").flatMap {
                            PortalRequestURL.url($0, relativeTo: url)?.absoluteURL
                        } ?? scriptNext
                    if let next, ["http", "https"].contains(next.scheme ?? "") {
                        item["location"] = next.absoluteString
                        if response.header("location") == nil {
                            item["js_redirect"] = scriptNext?.absoluteString
                        }
                        current = next
                    } else {
                        finalURL = url
                        finalBody = response.text
                        current = nil
                    }
                    chain.append(item)
                } catch {
                    chain.append([
                        "seq": sequence, "url": url.absoluteString,
                        "error": "transport_unavailable",
                    ])
                    break
                }
            }
            try PrivateFile.writeJSON(
                chain, to: directory.appendingPathComponent("portal_chain.json"))
            if let finalURL,
                let doc = try? XMLDocument(
                    xmlString: finalBody,
                    options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
                let scripts = try? doc.nodes(forXPath: "//script[@src]/@src")
            {
                var index: [[String: Any]] = []
                for (i, node) in scripts.prefix(4).enumerated() {
                    guard let src = node.stringValue,
                        let url = PortalRequestURL.url(src, relativeTo: finalURL)?.absoluteURL,
                        ["http", "https"].contains(url.scheme ?? ""), deadline > Date()
                    else { continue }
                    let file =
                        String(format: "%02d_", i + 1)
                        + EvidenceStore.safeKey(url.lastPathComponent)
                    if let response = try? await client.send(
                        HTTPRequest(
                            url: url, timeout: min(3, deadline.timeIntervalSinceNow),
                            followRedirects: false, maximumBodyBytes: 524_288))
                    {
                        try PrivateFile.write(
                            response.body,
                            to: directory.appendingPathComponent("portal/scripts/" + file))
                        index.append([
                            "url": url.absoluteString, "status": response.status, "file": file,
                        ])
                    }
                }
                try PrivateFile.writeJSON(
                    index, to: directory.appendingPathComponent("portal/scripts/index.json"))
            }
            var cnaURL: URL?
            if deadline > Date(), !Task.isCancelled {
                let log = await commands.run(
                    "/usr/bin/log",
                    arguments: [
                        "show", "--style", "compact", "--last", "2m", "--predicate",
                        "(subsystem CONTAINS[c] \"captive\") OR (process == \"CaptiveNetworkAssistant\")",
                    ], timeout: min(6, deadline.timeIntervalSinceNow))
                let text = log.text.components(separatedBy: .newlines).suffix(1200).joined(
                    separator: "\n")
                try PrivateFile.write(
                    Data(text.utf8), to: directory.appendingPathComponent("cna_log.txt"))
                cnaURL = CaptivePortalDiscovery.extract(logText: text, gatewayIP: network.gatewayIP)
            }
            var summary = environment
            summary["http_intercepted_to"] = discovered?.absoluteString
            summary["cna_portal_url"] = cnaURL?.absoluteString
            summary["portal_chain_hops"] = chain.count
            summary["portal_final_url"] = finalURL?.absoluteString
            summary["portal_final_analysis"] = finalURL == nil ? nil : Self.analyze(finalBody)
            summary["dns_servers_responding"] = matrix.serversResponding
            summary["errors"] = errors
            var notes = [
                "Native diagnostics; raw artifacts are private and do not prove internet access."
            ]
            if let gateway = network.gatewayIP, finalURL?.host == gateway {
                notes.append("The gateway serves the portal itself.")
            }
            if finalURL == nil && cnaURL == nil && discovered == nil {
                notes.append(
                    "No portal URL discovered in bounded HTTP or captive-assistant evidence.")
            }
            summary["notes"] = notes
            try PrivateFile.writeJSON(summary, to: directory.appendingPathComponent("summary.json"))
            try PrivateFile.write(
                Data(String(now).utf8), to: parent.appendingPathComponent("last_sweep_ts"))
            let old =
                ((try? FileManager.default.contentsOfDirectory(
                    at: parent, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter {
                    (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for entry in old.prefix(max(0, old.count - 8)) { PrivateFile.remove(entry) }
            return directory
        } catch { return nil }
    }
    public static func analyze(_ html: String) -> [String: Any] {
        let document = try? XMLDocument(
            xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        func count(_ xpath: String) -> Int { (try? document?.nodes(forXPath: xpath).count) ?? 0 }
        let forms = count("//form")
        let scripts = count("//script")
        return [
            "forms": forms, "scripts": scripts, "inputs": count("//input"),
            "looks_js_rendered": forms == 0 && scripts > 0,
            "title": (try? document?.nodes(forXPath: "//title").first?.stringValue) ?? "",
        ]
    }
    private static func scriptRedirect(_ html: String, base: URL) -> URL? {
        if let regex = try? NSRegularExpression(
            pattern:
                "(?:window\\.)?location(?:(?:\\.href)?\\s*=|\\.replace\\s*\\()\\s*['\"]([^'\"]+)['\"]",
            options: .caseInsensitive),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html),
            let target = PortalRequestURL.url(String(html[range]), relativeTo: base)?.absoluteURL,
            target != base
        {
            return target
        }
        // Reviewed Purple shim: prove JavaScript support without evaluating code.
        if html.contains("jsrd=1"), html.contains("location.search"),
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
            !(components.queryItems ?? []).contains(where: { $0.name == "jsrd" && $0.value == "1" })
        {
            components.percentEncodedQuery =
                (components.percentEncodedQuery.map { $0.isEmpty ? "" : $0 + "&" } ?? "") + "jsrd=1"
            return components.url
        }
        return nil
    }
}

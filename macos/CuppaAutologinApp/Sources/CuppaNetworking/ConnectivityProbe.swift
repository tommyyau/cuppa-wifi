import CuppaCore
import Foundation

public enum ProbeState: String, Sendable {
    case online = "ONLINE"
    case captive = "CAPTIVE"
    case noNetwork = "NO_NETWORK"
}
public struct ProbeResult: Sendable {
    public var state: ProbeState
    public var redirectURL: URL?
    public var body: String?
    public var source: String
    public var errors: [String]
    public init(
        state: ProbeState, redirectURL: URL? = nil, body: String? = nil, source: String = "",
        errors: [String] = []
    ) {
        self.state = state
        self.redirectURL = redirectURL
        self.body = body
        self.source = source
        self.errors = errors
    }
}
public struct ConnectivityProbe: Sendable {
    private let client: any HTTPClient
    public static let appleURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    public static let googleURL = URL(string: "http://connectivitycheck.gstatic.com/generate_204")!
    public init(client: any HTTPClient) { self.client = client }
    public static func isAppleSuccess(_ body: String) -> Bool {
        var compact = body.lowercased().filter { !$0.isWhitespace }
        if compact.hasPrefix("\u{feff}") { compact.removeFirst() }
        if compact.hasPrefix("<!doctypehtml>") { compact.removeFirst(14) }
        return [
            "success", "<html><body>success</body></html>",
            "<html><head><title>success</title></head><body>success</body></html>",
        ].contains(compact)
    }
    public func check(captiveHint: Bool = false, requireConsensus: Bool = false) async
        -> ProbeResult
    {
        var errors: [String] = []
        func probe(_ url: URL, source: String) async -> ProbeResult? {
            do {
                let response = try await client.send(
                    HTTPRequest(
                        url: url, timeout: 5, followRedirects: false, maximumBodyBytes: 65_536))
                if (300..<400).contains(response.status) {
                    return ProbeResult(
                        state: .captive,
                        redirectURL: response.header("location").flatMap {
                            PortalRequestURL.url($0, relativeTo: url)?.absoluteURL
                        }, source: source)
                }
                let online =
                    !response.truncated
                    && (source == "apple"
                        ? response.status == 200 && Self.isAppleSuccess(response.text)
                        : response.status == 204)
                return ProbeResult(
                    state: online ? .online : .captive,
                    body: online
                        ? nil : String(decoding: response.body.prefix(65_536), as: UTF8.self),
                    source: source)
            } catch {
                // Preserve useful categories without retaining token-bearing exception strings.
                errors.append("\(source):\(Self.errorCategory(error))")
                return nil
            }
        }
        if let apple = await probe(Self.appleURL, source: "apple") {
            if apple.state == .captive || !(captiveHint || requireConsensus) { return apple }
            if let google = await probe(Self.googleURL, source: "gstatic") {
                if google.state == .online {
                    return ProbeResult(state: .online, source: "apple+gstatic", errors: errors)
                }
                return google
            }
            return ProbeResult(
                state: .captive,
                source: captiveHint ? "macos-captive-state" : "connectivity-consensus",
                errors: errors)
        }
        if var google = await probe(Self.googleURL, source: "gstatic") {
            if google.state == .online && (captiveHint || requireConsensus) {
                return ProbeResult(
                    state: .captive,
                    source: captiveHint ? "macos-captive-state" : "connectivity-consensus",
                    errors: errors)
            }
            google.errors = errors
            return google
        }
        return ProbeResult(
            state: captiveHint && !errors.contains(where: { $0.hasSuffix(":proxy_detected") })
                ? .captive : .noNetwork,
            source: captiveHint ? "macos-captive-state" : "", errors: errors)
    }
    public static func errorCategory(_ error: Error) -> String {
        if let error = error as? HTTPTransportError { return error.category }
        if let error = error as? NativeNetworkError {
            switch error {
            case .proxyDetected: return "proxy_detected"
            case .dnsFailure: return "dns_failed"
            case .timeout: return "request_timeout"
            default: return "request_failed"
            }
        }
        let foundationError = error as NSError
        if foundationError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: foundationError.code) {
            case .timedOut: return "request_timeout"
            case .cannotFindHost, .dnsLookupFailed: return "dns_failed"
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet,
                .internationalRoamingOff, .dataNotAllowed:
                return "unreachable"
            case .noPermissionsToReadFile: return "permission_denied"
            default: break
            }
        }
        let text = String(describing: error).lowercased()
        if text.contains("dns") || text.contains("nodename") { return "dns_failed" }
        if text.contains("permission") || text.contains("not permitted") {
            return "permission_denied"
        }
        if text.contains("timeout") || text.contains("timed out") { return "request_timeout" }
        if text.contains("unreachable") || text.contains("no route") { return "unreachable" }
        return "request_failed"
    }
}

public enum CaptivePortalDiscovery {
    public static func extract(logText: String, gatewayIP: String?) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"\bURL:\s*(https?://[^\"\s>]+)"#)
        else { return nil }
        var newest: URL?
        for match in regex.matches(in: logText, range: NSRange(logText.startIndex..., in: logText))
        {
            guard let range = Range(match.range(at: 1), in: logText),
                let url = URL(string: String(logText[range])),
                let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false),
                parsed.scheme == "https", parsed.host?.lowercased() == "wifi.wireless-social.com",
                parsed.path == "/login/fortinet/fortigate", parsed.user == nil,
                parsed.password == nil,
                let post = parsed.queryItems?.first(where: { $0.name == "post" })?.value,
                let magic = parsed.queryItems?.first(where: { $0.name == "magic" })?.value,
                (8...64).contains(magic.count),
                magic.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }),
                let callback = URLComponents(string: post), callback.scheme == "http",
                callback.path == "/fgtauth", callback.port == 1000,
                let callbackHost = callback.host, callback.user == nil, callback.password == nil,
                gatewayIP == nil || callbackHost == gatewayIP
            else { continue }
            newest = url
        }
        return newest
    }
    public static func discover(
        gatewayIP: String?, commands: any SystemCommandRunning = NativeSystemCommands()
    ) async -> URL? {
        let output = await commands.run(
            "/usr/bin/log",
            arguments: [
                "show", "--style", "compact", "--last", "2m", "--predicate",
                #"(subsystem CONTAINS[c] "captive") OR (process == "CaptiveNetworkAssistant")"#,
            ], timeout: 6)
        guard output.status == 0 && !output.timedOut else { return nil }
        return extract(logText: output.text, gatewayIP: gatewayIP)
    }
}

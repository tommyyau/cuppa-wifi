import CuppaCore
import Darwin
import Foundation
import XCTest

@testable import CuppaNetworking

private actor ParityClient: HTTPClient {
    var responses: [Result<HTTPResponse, Error>]
    var requests: [HTTPRequest] = []
    init(_ responses: [Result<HTTPResponse, Error>] = []) { self.responses = responses }
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw NativeNetworkError.timeout }
        return try responses.removeFirst().get()
    }
    func count() -> Int { requests.count }
    func all() -> [HTTPRequest] { requests }
}
private actor ParityCommands: SystemCommandRunning {
    let address: String
    let ping: Int32
    var calls: [(String, [String], TimeInterval)] = []
    init(address: String = "10.0.0.42", ping: Int32 = 2) {
        self.address = address
        self.ping = ping
    }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandOutput {
        calls.append((executable, arguments, timeout))
        return CommandOutput(
            status: executable == "/sbin/ping" ? ping : 0,
            text: executable == "/usr/sbin/ipconfig" ? address : "")
    }
    func count() -> Int { calls.count }
}
private final class ProgressCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var titles: [String] = []
    func append(_ title: String) {
        lock.lock()
        titles.append(title)
        lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }
}
private final class IPv6Fixture: @unchecked Sendable {
    let fd: Int32
    var port: UInt16 = 0
    init(udp: Bool = false) throws {
        fd = socket(AF_INET6, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeNetworkError.invalidRequest }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        _ = inet_pton(AF_INET6, "::1", &address.sin6_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw NativeNetworkError.invalidRequest
        }
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin6_port)
        if !udp { guard listen(fd, 8) == 0 else { throw NativeNetworkError.invalidRequest } }
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
    func http() -> Task<String, Never> {
        Task.detached { [self] in
            let peer = accept(fd, nil, nil)
            guard peer >= 0 else { return "" }
            defer { close(peer) }
            var timeout = timeval(tv_sec: 4, tv_usec: 0)
            _ = setsockopt(
                peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var byte: UInt8 = 0
            while !data.suffix(4).elementsEqual([13, 10, 13, 10]), data.count < 16384 {
                guard recv(peer, &byte, 1, 0) == 1 else { break }
                data.append(byte)
            }
            let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nipv6".utf8)
            _ = reply.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
            return String(decoding: data, as: UTF8.self)
        }
    }
    func dns() -> Task<Void, Never> {
        Task.detached { [self] in
            var bytes = [UInt8](repeating: 0, count: 4096)
            var peer = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &bytes, bytes.count, 0, $0, &length)
                }
            }
            guard count >= 12 else { return }
            var answer = Data(bytes.prefix(count))
            answer[2] = 0x81
            answer[3] = 0x80
            answer[7] = 1
            answer.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 0, 0, 7])
            _ = answer.withUnsafeBytes { payload in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, payload.baseAddress, payload.count, 0, $0, length)
                    }
                }
            }
        }
    }
}
final class NetworkParityTests: XCTestCase, @unchecked Sendable {
    func testNativeQuietAbsoluteCommandAndRelativeRejection() async throws {
        let output = try await NativeSystemCommands().capture("/usr/bin/true", arguments: [])
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.text, "")
        XCTAssertFalse(output.timedOut)
        do {
            _ = try await NativeSystemCommands().capture("osascript", arguments: [])
            XCTFail("Relative command accepted")
        } catch { XCTAssertEqual(error as? NativeNetworkError, .invalidRequest) }
    }
    func testNativeCaptureStdoutStdinStderrAndNonzeroExit() async throws {
        let echo = try await NativeSystemCommands().capture("/bin/echo", arguments: ["hello"])
        XCTAssertEqual(echo.text, "hello\n")
        XCTAssertEqual(echo.status, 0)
        let cat = try await NativeSystemCommands().capture(
            "/bin/cat", arguments: [], stdin: Data("piped-in".utf8))
        XCTAssertEqual(cat.text, "piped-in")
        XCTAssertEqual(cat.status, 0)
        let failure = try await NativeSystemCommands().capture(
            "/bin/sh", arguments: ["-c", "printf diagnostic >&2; exit 7"])
        XCTAssertEqual(failure.status, 7)
        XCTAssertEqual(failure.stderr, "diagnostic")
        XCTAssertEqual(failure.text, "")
    }
    func testNativeTimeoutKillsAndReapsChild() async throws {
        let start = Date()
        let result = try await NativeSystemCommands().capture(
            "/bin/sh", arguments: ["-c", "echo $$; trap '' TERM; exec /bin/sleep 30"], timeout: 0.15
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.status, -1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        let pid = try XCTUnwrap(Int32(result.text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        var status: Int32 = 0
        XCTAssertEqual(waitpid(pid, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }
    func testNativeMissingExecutableThrowsAndRunReportsUnavailable() async throws {
        let path = "/tmp/cuppa-missing-" + UUID().uuidString
        do {
            _ = try await NativeSystemCommands().capture(path, arguments: [])
            XCTFail("Missing executable accepted")
        } catch {}
        let result = await NativeSystemCommands().run(path, arguments: [], timeout: 1)
        XCTAssertEqual(result.status, -1)
        XCTAssertFalse(result.timedOut)
    }
    func testNativeLargeOutputIsCappedWithoutPipeDeadlock() async throws {
        let output = try await NativeSystemCommands().capture(
            "/bin/dd", arguments: ["if=/dev/zero", "bs=1024", "count=4096"], timeout: 3,
            maximumOutputBytes: 32768)
        XCTAssertEqual(output.status, 0)
        XCTAssertFalse(output.timedOut)
        XCTAssertEqual(output.text.utf8.count, 32768)
        XCTAssertFalse(output.stderr.isEmpty)
    }
    func testIPv6HTTPUsesSelectedInterfaceAndCorrectHostHeader() async throws {
        let fixture = try IPv6Fixture()
        defer { fixture.stop() }
        let wire = fixture.http()
        let result = try await NativeHTTPClient(network: NetworkSnapshot(interface: "lo0")).send(
            HTTPRequest(url: URL(string: "http://[::1]:\(fixture.port)/six")!, timeout: 3))
        XCTAssertEqual(result.text, "ipv6")
        XCTAssertEqual(result.status, 200)
        let request = await wire.value
        XCTAssertTrue(request.contains("Host: [::1]:\(fixture.port)\r\n"))
        XCTAssertTrue(request.hasPrefix("GET /six HTTP/1.1"))
    }
    func testIPv6ScopedUDPDNSAndCache() async throws {
        let fixture = try IPv6Fixture(udp: true)
        defer { fixture.stop() }
        let reply = fixture.dns()
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "lo0"), servers: ["::1"], dnsPort: fixture.port)
        let addresses = try await resolver.fallback(
            "ipv6.test", deadline: Date().addingTimeInterval(3))
        XCTAssertEqual(addresses, ["10.0.0.7"])
        await reply.value
        let cached = try await resolver.fallback(
            "ipv6.test", deadline: Date().addingTimeInterval(0.01))
        XCTAssertEqual(cached, addresses)
    }
    func testIPv6PortalRelayTunnelsAuthenticatedBytes() async throws {
        let fixture = try IPv6Fixture()
        defer { fixture.stop() }
        let wire = fixture.http()
        let relay = try BrowserRelay(
            network: NetworkSnapshot(interface: "lo0"),
            portalURL: URL(string: "http://[::1]:\(fixture.port)/")!)
        let config = try await relay.start()
        defer { Task { await relay.stop() } }
        let connection = try ScopedConnection(
            host: "127.0.0.1", port: config.port, interface: nil,
            deadline: Date().addingTimeInterval(4))
        defer { connection.close() }
        try await connection.open()
        let auth = Data(config.credential.utf8).base64EncodedString()
        try await connection.send(
            Data(
                "CONNECT [::1]:\(fixture.port) HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n"
                    .utf8))
        let connected = try await connection.receive()
        XCTAssertTrue(String(decoding: connected, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        try await connection.send(Data("GET /relay-six HTTP/1.1\r\nHost: [::1]\r\n\r\n".utf8))
        let received = try await connection.receive()
        XCTAssertTrue(String(decoding: received, as: UTF8.self).hasSuffix("ipv6"))
        let request = await wire.value
        XCTAssertTrue(request.hasPrefix("GET /relay-six"))
        XCTAssertEqual(relay.connections, 1)
        await relay.stop()
    }
    func testRelayExplicitPortalAndGatewayExceptionsAreNarrow() async throws {
        let relay = try BrowserRelay(
            network: NetworkSnapshot(gatewayIP: "192.168.1.1"),
            portalURL: URL(string: "http://192.168.1.2:8080/")!)
        for (host, port, expected) in [
            ("192.168.1.2", UInt16(8080), true), ("192.168.1.3", 8080, false),
            ("192.168.1.2", 22, false), ("192.168.1.1", 1000, true), ("192.168.1.1", 80, true),
            ("192.168.1.1", 22, false), ("192.168.1.3", 1000, false), ("localhost", 80, false),
            ("127.0.0.1", 443, false),
        ] {
            let allowed = await relay.permitted(host: host, port: port)
            XCTAssertEqual(allowed, expected, "\(host):\(port)")
        }
    }
    func testDiagnosticNoWiFiAndSelfAssignedAddressPerformNoHTTP() async {
        for (network, address, reason) in [
            (NetworkSnapshot(), "10.0.0.2", "wifi_not_connected"),
            (
                NetworkSnapshot(interface: "en0", gatewayIP: "10.0.0.1"), "169.254.1.7",
                "address_unavailable"
            ),
        ] {
            let commands = ParityCommands(address: address)
            let client = ParityClient()
            let result = await NetworkDiagnostics(
                client: client, network: network, commands: commands
            ).diagnose()
            XCTAssertEqual(result.evidence["reason"] as? String, reason)
            let count = await client.count()
            XCTAssertEqual(count, 0)
            let calls = await commands.count()
            XCTAssertEqual(calls, network.interface == nil ? 0 : 1)
            if reason == "address_unavailable" {
                XCTAssertTrue(NetworkDiagnostics.summary(result.evidence).1.contains("IPv6"))
            }
        }
    }
    func testProxyInterferenceRemainsUnverifiedAndDoesNotDiagnoseVenueFailure() async {
        let client = ParityClient([
            .failure(NativeNetworkError.proxyDetected),
            .failure(NativeNetworkError.proxyDetected),
        ])
        let probe = await ConnectivityProbe(client: client).check()
        XCTAssertEqual(probe.state, .noNetwork)
        XCTAssertEqual(probe.errors, ["apple:proxy_detected", "gstatic:proxy_detected"])
        let hintedClient = ParityClient([
            .failure(NativeNetworkError.proxyDetected), .failure(NativeNetworkError.proxyDetected),
        ])
        let hinted = await ConnectivityProbe(client: hintedClient).check(captiveHint: true)
        XCTAssertEqual(hinted.state, .noNetwork, "Proxy failures cannot authorize a portal attempt")
        let commands = ParityCommands()
        let diagnosis = await NetworkDiagnostics(
            client: client, network: NetworkSnapshot(interface: "en0", gatewayIP: "10.0.0.1"),
            commands: commands
        ).diagnose(errors: probe.errors)
        XCTAssertNil(diagnosis.portalURL)
        XCTAssertEqual(diagnosis.evidence["reason"] as? String, "proxy_interference")
        XCTAssertEqual(diagnosis.evidence["probe_errors"] as? [String], probe.errors)
        let requests = await client.count()
        XCTAssertEqual(requests, 2, "Do not probe the gateway after identifying proxy interference")
        let calls = await commands.count()
        XCTAssertEqual(calls, 1, "Check address readiness without diagnosing a router fault")
        let recorded = NetworkDiagnostics.record(
            diagnosis, previous: [:], fingerprint: "synthetic", now: 100)
        let summary = NetworkDiagnostics.summary(recorded)
        XCTAssertEqual(summary.0, "Direct Wi-Fi check blocked by a proxy")
        XCTAssertTrue(summary.1.contains("reduces Private Relay protection"))
        XCTAssertEqual(ConnectivityProbe.errorCategory(NativeNetworkError.forbiddenDestination), "request_failed")
    }

    func testDiagnosticFailureEvidenceProgressAndRepeatWindows() async {
        let client = ParityClient()
        let commands = ParityCommands()
        let progress = ProgressCapture()
        let result = await NetworkDiagnostics(
            client: client,
            network: NetworkSnapshot(
                interface: "en0", gatewayIP: "10.0.0.1", captiveStage: "Evaluate"),
            commands: commands
        ).diagnose(
            errors: ["apple: DNS timed out secret@example.test", "gstatic: DNS timed out"],
            progress: { title, _ in progress.append(title) })
        XCTAssertEqual(result.evidence["reason"] as? String, "network_path_unavailable")
        XCTAssertEqual(result.evidence["interface"] as? String, "en0")
        XCTAssertEqual(result.evidence["address_assigned"] as? Bool, true)
        XCTAssertEqual(result.evidence["gateway_present"] as? Bool, true)
        XCTAssertEqual(result.evidence["gateway_ping"] as? String, "no_reply")
        XCTAssertEqual(result.evidence["macos_stage"] as? String, "evaluate")
        XCTAssertEqual(
            result.evidence["probe_errors"] as? [String],
            ["apple:dns_timeout", "gstatic:dns_timeout"])
        XCTAssertEqual(
            progress.snapshot(),
            [
                "Checking the Wi-Fi address", "Checking the Wi-Fi gateway",
                "Looking for a portal without DNS",
            ])
        for key in ["gateway_http", "direct_http"] {
            XCTAssertEqual(
                (result.evidence[key] as? [String: Any])?["result"] as? String, "timeout")
        }
        let requests = await client.all()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.timeout, 2)
            XCTAssertFalse(request.followRedirects)
            XCTAssertEqual(request.maximumBodyBytes, 0)
            XCTAssertEqual(request.headers["Cookie"], "")
        }
        let first = NetworkDiagnostics.record(result, previous: [:], fingerprint: "venue", now: 100)
        XCTAssertEqual(first["repeated"] as? Bool, false)
        let repeated = NetworkDiagnostics.record(
            result, previous: first, fingerprint: "venue", now: 130)
        XCTAssertEqual(repeated["repeated"] as? Bool, true)
        XCTAssertEqual(repeated["title"] as? String, "Likely network problem")
        XCTAssertTrue((repeated["detail"] as? String ?? "").contains("filtering"))
        for (fingerprint, now) in [
            ("other", 140.0), ("venue", 400.0), ("venue", 90.0), ("venue", 101.0),
        ] {
            XCTAssertEqual(
                NetworkDiagnostics.record(
                    result, previous: first, fingerprint: fingerprint, now: now)["repeated"]
                    as? Bool, false)
        }
        var malformed = first
        malformed["first_seen_at"] = NSNull()
        malformed["consecutive_checks"] = "bad"
        XCTAssertEqual(
            NetworkDiagnostics.record(result, previous: malformed, fingerprint: "venue", now: 130)[
                "repeated"] as? Bool, false)
    }
    func testDiagnosticFilteredPingDirectResponsesAndPermissionReasons() async {
        let url = URL(string: "http://1.1.1.1/")!
        let cases: [([Result<HTTPResponse, Error>], String)] = [
            (
                [
                    .success(HTTPResponse(url: url, status: 403)),
                    .failure(NativeNetworkError.timeout),
                ], "upstream_unavailable"
            ),
            (
                [
                    .success(HTTPResponse(url: url, status: 200)),
                    .success(HTTPResponse(url: url, status: 200)),
                ], "dns_or_probe_failure"
            ),
            (
                [
                    .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))),
                    .failure(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))),
                ], "network_permission_denied"
            ),
        ]
        for (responses, reason) in cases {
            let result = await NetworkDiagnostics(
                client: ParityClient(responses),
                network: NetworkSnapshot(interface: "en0", gatewayIP: "10.0.0.1"),
                commands: ParityCommands()
            ).diagnose()
            XCTAssertEqual(result.evidence["reason"] as? String, reason)
        }
    }
    func testDiagnosticPortalTokenOnlyInReturnedURLAndRedirectRejections() async {
        let raw = URL(string: "http://1.1.1.1/")!
        let portal = "https://portal.example/splash?token=private-fixture"
        let result = await NetworkDiagnostics(
            client: ParityClient([
                .failure(NativeNetworkError.timeout),
                .success(HTTPResponse(url: raw, status: 302, headers: ["Location": portal])),
            ]), network: NetworkSnapshot(interface: "en0", gatewayIP: "10.0.0.1"),
            commands: ParityCommands()
        ).diagnose()
        XCTAssertEqual(result.portalURL?.absoluteString, portal)
        XCTAssertFalse(String(describing: result.evidence).contains("private-fixture"))
        XCTAssertEqual((result.evidence["direct_http"] as? [String: Any])?["status"] as? Int, 302)
        XCTAssertEqual(
            (result.evidence["direct_http"] as? [String: Any])?["connected"] as? Bool, true)
        for location in [
            "https://one.one.one.one/", "https://1.1.1.1/", "https://www.cloudflare.com/",
            "file:///etc/passwd", "http://127.0.0.1/", "https://u:p@portal.example/",
            "https://portal.example:9000/",
        ] {
            XCTAssertNil(
                NetworkDiagnostics.portalRedirect(
                    from: raw, location: location, gateway: "10.0.0.1"), location)
        }
        XCTAssertNil(
            NetworkDiagnostics.portalRedirect(
                from: URL(string: "http://10.0.0.1/")!, location: "/admin", gateway: "10.0.0.1"))
        XCTAssertNotNil(
            NetworkDiagnostics.portalRedirect(
                from: URL(string: "http://10.0.0.1/")!, location: "/guest/portal",
                gateway: "10.0.0.1"))
    }
}

private actor DiscoveryCommands: SystemCommandRunning {
    let output: CommandOutput
    var seen: [(String, TimeInterval)] = []
    init(_ output: CommandOutput) { self.output = output }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandOutput {
        seen.append((executable, timeout))
        return output
    }
    func calls() -> [(String, TimeInterval)] { seen }
}
private actor InspectorCommands: SystemCommandRunning {
    let active: Bool
    var calls: [[String]] = []
    init(active: Bool) { self.active = active }
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandOutput {
        calls.append([executable] + arguments)
        let text: String
        switch arguments.first {
        case "-listallhardwareports": text = "Hardware Port: Wi-Fi\nDevice: en0\n"
        case "getifaddr": text = active ? "192.0.2.20\n" : ""
        case "-n" where executable == "/sbin/route":
            text = arguments.contains("-ifscope") ? "gateway: 192.0.2.1\ninterface: en0\n" : ""
        case "en0": text = "status: inactive\n"
        case "-n" where executable == "/usr/sbin/arp": text = "? (192.0.2.1) at 2:0:0:0:0:1 on en0"
        default: text = ""
        }
        return CommandOutput(status: 0, text: text)
    }
    func all() -> [[String]] { calls }
}
extension NetworkParityTests {
    func testCaptiveDiscoveryExactContractRejectsEachMismatchAndChoosesNewest() async {
        let good =
            "https://wifi.wireless-social.com/login/fortinet/fortigate?login&post=http://10.0.0.1:1000/fgtauth&magic=0000000000000000&ssid=Example%20Guest%20Wi-Fi"
        XCTAssertEqual(
            CaptivePortalDiscovery.extract(logText: "URL: \(good)", gatewayIP: "10.0.0.1")?
                .absoluteString, good)
        XCTAssertNil(CaptivePortalDiscovery.extract(logText: "URL: \(good)", gatewayIP: "10.0.0.9"))
        for bad in [
            good.replacingOccurrences(of: "wifi.wireless-social.com", with: "attacker.example"),
            good.replacingOccurrences(of: ":1000/fgtauth", with: ":80/fgtauth"),
            good.replacingOccurrences(of: "/fgtauth", with: "/admin"),
            good.replacingOccurrences(of: "0000000000000000", with: "not-a-token"),
        ] {
            XCTAssertNil(
                CaptivePortalDiscovery.extract(logText: "URL: \(bad)", gatewayIP: "10.0.0.1"))
        }
        let newer = good.replacingOccurrences(of: "0000000000000000", with: "2222222222222222")
        XCTAssertEqual(
            CaptivePortalDiscovery.extract(
                logText: "URL: \(good)\nURL: \(newer)", gatewayIP: "10.0.0.1")?.absoluteString,
            newer)
        let commands = DiscoveryCommands(CommandOutput(status: 0, text: "URL: \(good)"))
        let discovered = await CaptivePortalDiscovery.discover(
            gatewayIP: "10.0.0.1", commands: commands)
        XCTAssertEqual(discovered?.absoluteString, good)
        let calls = await commands.calls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, "/usr/bin/log")
        XCTAssertLessThanOrEqual(calls.first!.1, 6)
        let failed = await CaptivePortalDiscovery.discover(
            gatewayIP: "10.0.0.1",
            commands: DiscoveryCommands(CommandOutput(status: 1, text: "URL: \(good)")))
        XCTAssertNil(failed)
    }
    func testInspectorNoDefaultRouteStaleKeyAndScopedRouteMAC() async {
        let active = InspectorCommands(active: true)
        let snapshot = await NativeNetworkInspector(
            commands: active,
            captiveStatus: { _ in CaptiveNetworkRecord(stage: "WebSheet", waitingOnUI: true) }
        ).current()
        XCTAssertEqual(snapshot.interface, "en0")
        XCTAssertEqual(snapshot.gatewayIP, "192.0.2.1")
        XCTAssertEqual(snapshot.gatewayMAC, "02:00:00:00:00:01")
        XCTAssertEqual(snapshot.captiveStage, "WebSheet")
        XCTAssertTrue(snapshot.captiveHint)
        let calls = await active.all()
        XCTAssertTrue(calls.contains(["/sbin/route", "-n", "get", "-ifscope", "en0", "default"]))
        let inactive = await NativeNetworkInspector(
            commands: InspectorCommands(active: false),
            captiveStatus: { _ in CaptiveNetworkRecord(stage: "Offline") }
        ).current()
        XCTAssertNil(inactive.interface)
        XCTAssertFalse(CaptiveNetworkRecord(stage: "Online").isCaptive)
        XCTAssertFalse(CaptiveNetworkRecord(stage: "Evaluate").isCaptive)
        XCTAssertTrue(CaptiveNetworkRecord(stage: "Evaluate", waitingOnUI: true).isCaptive)
    }
    func testProbeExactResponsesRelativeRedirectsBodyLimitAndFallbackErrors() async {
        let apple = ConnectivityProbe.appleURL
        let google = ConnectivityProbe.googleURL
        for document in [
            "<HTML><BODY>Success</BODY></HTML>",
            "\u{feff}<!doctype html><HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>",
        ] {
            let result = await ConnectivityProbe(
                client: ParityClient([
                    .success(HTTPResponse(url: apple, status: 200, body: Data(document.utf8)))
                ])
            ).check()
            XCTAssertEqual(result.state, .online)
            XCTAssertEqual(result.source, "apple")
        }
        for document in [
            "<html><body>Successfully loaded portal</body></html>",
            "<HTML><BODY>Success<script>boot()</script></BODY></HTML>",
            "<html>Sign in to WiFi</html>",
        ] {
            let result = await ConnectivityProbe(
                client: ParityClient([
                    .success(HTTPResponse(url: apple, status: 200, body: Data(document.utf8)))
                ])
            ).check()
            XCTAssertEqual(result.state, .captive)
            XCTAssertEqual(result.body, document)
        }
        let oversized = await ConnectivityProbe(
            client: ParityClient([
                .success(
                    HTTPResponse(url: apple, status: 200, body: Data(repeating: 65, count: 100000)))
            ])
        ).check()
        XCTAssertEqual(oversized.state, .captive)
        XCTAssertEqual(oversized.body?.utf8.count, 65536)
        for location in ["https://portal.example/login?mac=aa", "/portal"] {
            let result = await ConnectivityProbe(
                client: ParityClient([
                    .success(HTTPResponse(url: apple, status: 302, headers: ["Location": location]))
                ])
            ).check()
            XCTAssertEqual(result.state, .captive)
            XCTAssertEqual(
                result.redirectURL, URL(string: location, relativeTo: apple)?.absoluteURL)
        }
        let fallback = await ConnectivityProbe(
            client: ParityClient([
                .failure(HTTPTransportError(category: "request_timeout", connected: true)),
                .success(HTTPResponse(url: google, status: 204)),
            ])
        ).check()
        XCTAssertEqual(fallback.state, .online)
        XCTAssertEqual(fallback.source, "gstatic")
        XCTAssertEqual(fallback.errors, ["apple:request_timeout"])
        let timeout = await ConnectivityProbe(client: ParityClient()).check()
        XCTAssertEqual(timeout.state, .noNetwork)
        XCTAssertEqual(timeout.errors.count, 2)
        let hintedTimeout = await ConnectivityProbe(client: ParityClient()).check(captiveHint: true)
        XCTAssertEqual(hintedTimeout.state, .captive)
        XCTAssertEqual(hintedTimeout.source, "macos-captive-state")
        XCTAssertEqual(hintedTimeout.errors.count, 2)
    }
    func testProbeHintAndConsensusSecondaryInterceptionNeverReportsOnline() async {
        let apple = ConnectivityProbe.appleURL
        let google = ConnectivityProbe.googleURL
        for (hint, consensus) in [(true, false), (false, true)] {
            for response in [
                HTTPResponse(
                    url: google, status: 302, headers: ["Location": "https://portal.example/login"]),
                HTTPResponse(url: google, status: 200, body: Data("<html>Portal</html>".utf8)),
            ] {
                let result = await ConnectivityProbe(
                    client: ParityClient([
                        .success(HTTPResponse(url: apple, status: 200, body: Data("Success".utf8))),
                        .success(response),
                    ])
                ).check(captiveHint: hint, requireConsensus: consensus)
                XCTAssertEqual(result.state, .captive)
                XCTAssertEqual(result.source, "gstatic")
                if response.status == 302 {
                    XCTAssertEqual(
                        result.redirectURL?.absoluteString, "https://portal.example/login")
                } else {
                    XCTAssertEqual(result.body, "<html>Portal</html>")
                }
            }
            let result = await ConnectivityProbe(
                client: ParityClient([
                    .failure(NativeNetworkError.timeout),
                    .success(HTTPResponse(url: google, status: 204)),
                ])
            ).check(captiveHint: hint, requireConsensus: consensus)
            XCTAssertEqual(result.state, .captive)
            XCTAssertEqual(result.source, hint ? "macos-captive-state" : "connectivity-consensus")
            XCTAssertEqual(result.errors.count, 1)
        }
    }
    func testDNSConfiguredIPv6DHCPGatewayDedupAndAllFailures() async {
        let dns =
            "resolver #1\n nameserver[0] : 10.0.0.1\n nameserver[1] : fe80::1\n if_index : 6 (en0)\nresolver #2\n nameserver[0] : 9.9.9.9\n if_index : 7 (en1)\n"
        XCTAssertEqual(
            ScopedDNSResolver.servers(dns: dns, packet: "", interface: "en0", gateway: "10.0.0.1"),
            ["10.0.0.1", "fe80::1"])
        XCTAssertEqual(
            ScopedDNSResolver.servers(
                dns: "",
                packet: "domain_name_server (ip_mult): {8.8.8.8}\nrouter (ip_mult): {10.0.0.1}",
                interface: "en0", gateway: "10.0.0.1"), ["8.8.8.8", "10.0.0.1"])
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "en0"), servers: ["10.0.0.1"],
            queryServer: { interface, server, host, _, _ in
                XCTAssertEqual(interface, "en0")
                XCTAssertEqual(server, "10.0.0.1")
                XCTAssertEqual(host, "portal.test")
                throw NativeNetworkError.timeout
            })
        do {
            _ = try await resolver.fallback("portal.test", deadline: Date().addingTimeInterval(2))
            XCTFail("Failed DNS invented addresses")
        } catch { XCTAssertEqual(error as? NativeNetworkError, .dnsFailure) }
    }
}

private actor ResolutionOrder {
    var order: [String] = []
    func add(_ stage: String) { order.append(stage) }
    func all() -> [String] { order }
}
extension NetworkParityTests {
    func testDNSSystemFailureFallsBackBeforeReturningScopedAddresses() async throws {
        let order = ResolutionOrder()
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "en0"), servers: ["10.0.0.1"],
            queryServer: { interface, server, host, type, _ in
                XCTAssertEqual(interface, "en0")
                XCTAssertEqual(server, "10.0.0.1")
                XCTAssertEqual(host, "portal.example")
                XCTAssertEqual(type, 1)
                await order.add("scoped")
                return ["198.51.100.20"]
            },
            systemResolve: { host, _ in
                XCTAssertEqual(host, "portal.example")
                await order.add("system")
                throw NativeNetworkError.dnsFailure
            })
        let result = try await resolver.resolve(
            "portal.example", deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(result, ["198.51.100.20"])
        let stages = await order.all()
        XCTAssertEqual(stages, ["system", "scoped"])
    }
    func testIPv6GatewayDiagnosticsRemainUncertainWithoutIPv4Probe() async {
        for address in ["::1", "2001:db8::1"] {
            let client = ParityClient()
            let result = await NetworkDiagnostics(
                client: client, network: NetworkSnapshot(interface: "lo0", gatewayIP: address),
                commands: ParityCommands(address: address)
            ).diagnose()
            XCTAssertEqual(result.evidence["reason"] as? String, "gateway_unavailable")
            XCTAssertEqual(result.evidence["address_assigned"] as? Bool, true)
            XCTAssertEqual(result.evidence["gateway_present"] as? Bool, false)
            let count = await client.count()
            XCTAssertEqual(count, 0)
        }
    }
    func testSelectedInterfaceIsRequiredBeforeTCPStart() throws {
        let connection = try ScopedConnection(
            host: "127.0.0.1", port: 80, interface: "lo0", deadline: Date().addingTimeInterval(2))
        defer { connection.close() }
        XCTAssertEqual(connection.connection.parameters.requiredInterface?.name, "lo0")
        XCTAssertTrue(connection.connection.parameters.preferNoProxies)
    }
}
extension NetworkParityTests {
    func testObservedRedirectPreservesExistingEncodingAndEncodesRawSpaces() async {
        let location =
            "https://portal.example/login?ssid=Guest WiFi&callback=http%3A%2F%2F10.0.0.1%2F&mac=aa:bb"
        let expected =
            "https://portal.example/login?ssid=Guest%20WiFi&callback=http%3A%2F%2F10.0.0.1%2F&mac=aa:bb"
        let result = await ConnectivityProbe(
            client: ParityClient([
                .success(
                    HTTPResponse(
                        url: ConnectivityProbe.appleURL, status: 302,
                        headers: ["Location": location]))
            ])
        ).check()
        XCTAssertEqual(result.redirectURL?.absoluteString, expected)
        XCTAssertEqual(
            NetworkDiagnostics.portalRedirect(
                from: URL(string: "http://1.1.1.1/")!, location: location, gateway: "10.0.0.1")?
                .absoluteString, expected)
    }
}

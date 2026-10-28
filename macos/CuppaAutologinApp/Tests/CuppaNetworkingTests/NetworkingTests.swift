import CuppaCore
import Darwin
@preconcurrency import Dispatch
import Foundation
import Network
import Security
import XCTest

@testable import CuppaNetworking

private final class LoopbackServer: @unchecked Sendable {
    let fd: Int32
    var port: UInt16 = 0
    let lock = NSLock()
    var requests: [String] = []
    init(handler: @escaping @Sendable (Int32, String) -> Void) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeNetworkError.invalidRequest }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }) == 0, listen(fd, 32) == 0
        else { throw NativeNetworkError.invalidRequest }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                DispatchQueue.global().async { [self] in
                    defer { close(client) }
                    var timeout = timeval(tv_sec: 3, tv_usec: 0)
                    _ = setsockopt(
                        client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                        socklen_t(MemoryLayout<timeval>.size))
                    var request = Data()
                    var byte: UInt8 = 0
                    while !request.suffix(4).elementsEqual([13, 10, 13, 10])
                        && request.count < 20_000
                    {
                        guard recv(client, &byte, 1, 0) == 1 else { return }
                        request.append(byte)
                    }
                    let text = String(decoding: request, as: UTF8.self)
                    lock.lock()
                    requests.append(text)
                    lock.unlock()
                    handler(client, text)
                }
            }
        }
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
    static func write(_ fd: Int32, _ text: String) {
        let data = Data(text.utf8)
        data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < data.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
                if count <= 0 { return }
                sent += count
            }
        }
    }
}
private actor StubClient: HTTPClient {
    var results: [Result<HTTPResponse, Error>]
    var requests: [HTTPRequest] = []
    init(_ results: [Result<HTTPResponse, Error>]) { self.results = results }
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        requests.append(request)
        return try results.removeFirst().get()
    }
}
private struct StubCommands: SystemCommandRunning {
    var values: [String: String] = [:]
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandOutput {
        CommandOutput(
            status: 0, text: values[([executable] + arguments).joined(separator: " ")] ?? "")
    }
}
final class NetworkingTests: XCTestCase, @unchecked Sendable {
    func testChunkedPortalBodyAfterLargeBufferedChunk() async throws {
        // A portal can send several chunks in one socket read. Consuming the
        // first body advances Data.startIndex beyond the chunk-line limit.
        let chunks = [String(repeating: "a", count: 6_000),
                      String(repeating: "b", count: 5_000), "portal complete"]
        let wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + chunks.map { "\(String($0.utf8.count, radix: 16))\r\n\($0)\r\n" }.joined()
            + "0\r\n\r\n"
        let server = try LoopbackServer { fd, _ in LoopbackServer.write(fd, wire) }
        defer { server.stop() }
        let response = try await NativeHTTPClient(network: NetworkSnapshot(interface: "lo0"))
            .send(HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.text, chunks.joined())
        XCTAssertFalse(response.truncated)
    }

    func testHTTPRedirectCookiesAndChunkFraming() async throws {
        let server = try LoopbackServer { fd, request in
            if request.hasPrefix("POST /start ") {
                LoopbackServer.write(
                    fd,
                    "HTTP/1.1 302 Found\r\nLocation: /final\r\nSet-Cookie: session=abc; Path=/; HttpOnly\r\nSet-Cookie: secure=secret; Secure; Path=/\r\nContent-Length: 0\r\n\r\n"
                )
            } else {
                LoopbackServer.write(
                    fd,
                    "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;extension=ok\r\nabc\r\n2\r\nde\r\n0\r\n\r\n"
                )
            }
        }
        defer { server.stop() }
        let client = NativeHTTPClient(network: NetworkSnapshot())
        let response = try await client.send(
            HTTPRequest(
                url: URL(string: "http://127.0.0.1:\(server.port)/start")!, method: "POST",
                body: Data("a=1".utf8)))
        XCTAssertEqual(response.text, "abcde")
        XCTAssertEqual(response.url.path, "/final")
        let requests = server.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].hasPrefix("GET /final "))
        XCTAssertTrue(requests[1].contains("Cookie: session=abc\r\n"))
        XCTAssertFalse(requests[1].contains("secure=secret"))
        XCTAssertFalse(requests[1].contains("Content-Length:"))
        let cookies = await client.cookies()
        XCTAssertEqual(cookies.map(\.name), ["session"])
        let other = NativeHTTPClient(network: NetworkSnapshot())
        let otherCookies = await other.cookies()
        XCTAssertTrue(otherCookies.isEmpty)
    }
    func testScopedLoopbackAndBodyBound() async throws {
        let server = try LoopbackServer { fd, _ in
            LoopbackServer.write(fd, "HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n123456789")
        }
        defer { server.stop() }
        let client = NativeHTTPClient(network: NetworkSnapshot(interface: "lo0"))
        let response = try await client.send(
            HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, maximumBodyBytes: 4))
        XCTAssertEqual(response.text, "1234")
        XCTAssertTrue(response.truncated)
    }
    func testNoRedirectAndStatusOnlyNeverWaitForBody() async throws {
        let server = try LoopbackServer { fd, _ in
            LoopbackServer.write(
                fd, "HTTP/1.1 302 Found\r\nLocation: /sign-in\r\nContent-Length: 999\r\n\r\n")
        }
        defer { server.stop() }
        let client = NativeHTTPClient(network: NetworkSnapshot())
        let response = try await client.send(
            HTTPRequest(
                url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 1,
                followRedirects: false, maximumBodyBytes: 0))
        XCTAssertEqual(response.status, 302)
        XCTAssertEqual(server.snapshot().count, 1)
    }
    func testDeadlineAndInvalidInterfaceFailClosed() async throws {
        let server = try LoopbackServer { _, _ in Thread.sleep(forTimeInterval: 1) }
        defer { server.stop() }
        let client = NativeHTTPClient(network: NetworkSnapshot())
        let start = Date()
        do {
            _ = try await client.send(
                HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 0.15))
            XCTFail("Expected timeout")
        } catch { XCTAssertLessThan(Date().timeIntervalSince(start), 0.7) }
        let scoped = NativeHTTPClient(network: NetworkSnapshot(interface: "nonexistent"))
        do {
            _ = try await scoped.send(
                HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!))
            XCTFail("Must fail closed")
        } catch { XCTAssertEqual(error as? NativeNetworkError, .invalidInterface("nonexistent")) }
    }
    func testStrictAppleSuccessAndIndependentConsensus() async {
        XCTAssertFalse(ConnectivityProbe.isAppleSuccess("Successfully loaded"))
        XCTAssertFalse(ConnectivityProbe.isAppleSuccess("<script>var Success=1</script>"))
        XCTAssertTrue(
            ConnectivityProbe.isAppleSuccess("<!doctype html> <HTML><BODY> Success </BODY></HTML>"))
        let apple = HTTPResponse(
            url: ConnectivityProbe.appleURL, status: 200, body: Data("Success".utf8))
        let google = HTTPResponse(
            url: ConnectivityProbe.googleURL, status: 302, headers: ["Location": "/login"])
        let stub = StubClient([.success(apple), .success(google)])
        let result = await ConnectivityProbe(client: stub).check(captiveHint: true)
        XCTAssertEqual(result.state, .captive)
        XCTAssertEqual(
            result.redirectURL?.absoluteString, "http://connectivitycheck.gstatic.com/login")
        let requests = await stub.requests
        XCTAssertTrue(requests.allSatisfy { !$0.followRedirects && $0.maximumBodyBytes == 65_536 })
        let failing = StubClient([
            .failure(NativeNetworkError.dnsFailure),
            .success(HTTPResponse(url: ConnectivityProbe.googleURL, status: 204)),
        ])
        let consensus = await ConnectivityProbe(client: failing).check(requireConsensus: true)
        XCTAssertEqual(consensus.state, .captive)
        XCTAssertEqual(consensus.errors, ["apple:dns_failed"])
    }
    func testDNSPacketValidationAndScopedServers() throws {
        let query = try DNSPacket.query(host: "portal.test", id: 123, type: 1)
        var answer = query
        answer[2] = 0x81
        answer[3] = 0x80
        answer[6] = 0
        answer[7] = 1
        answer.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 168, 1, 1])
        XCTAssertEqual(try DNSPacket.addresses(answer, id: 123), ["192.168.1.1"])
        XCTAssertThrowsError(try DNSPacket.addresses(answer, id: 124))
        XCTAssertThrowsError(try DNSPacket.addresses(answer.dropLast(), id: 123))
        XCTAssertThrowsError(try DNSPacket.query(host: "a..test", id: 1, type: 1))
        let servers = ScopedDNSResolver.servers(
            dns:
                "resolver #1\n nameserver[0] : 8.8.8.8\n if_index : 4 (en1)\nresolver #2\n nameserver[0] : 10.0.0.2\n if_index : 5 (en0)\n",
            packet: "router (ip_mult): {10.0.0.1}", interface: "en0")
        XCTAssertEqual(servers, ["10.0.0.2", "10.0.0.1"])
    }
    func testRelayAuthenticationAndDestinationPolicy() async throws {
        let relay = try BrowserRelay(
            network: NetworkSnapshot(), portalURL: URL(string: "https://portal.test:8443/")!)
        let configuration = try await relay.start()
        defer { Task { await relay.stop() } }
        XCTAssertGreaterThan(configuration.port, 0)
        let allowedPortal = await relay.permitted(host: "portal.test", port: 8443)
        XCTAssertTrue(allowedPortal)
        let deniedLAN = await relay.permitted(host: "192.168.1.1", port: 443)
        XCTAssertFalse(deniedLAN)
        let deniedLocal = await relay.permitted(host: "anything.local", port: 443)
        XCTAssertFalse(deniedLocal)
        let connection = try ScopedConnection(
            host: "127.0.0.1", port: configuration.port, interface: nil,
            deadline: Date().addingTimeInterval(2))
        defer { connection.close() }
        try await connection.open()
        try await connection.send(
            Data("CONNECT portal.test:8443 HTTP/1.1\r\nHost: portal.test\r\n\r\n".utf8))
        let data = try await connection.receive()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("HTTP/1.1 407"))
        await relay.stop()
        let port = await relay.port
        XCTAssertEqual(port, 0)
    }
    func testAuthenticatedRelayTunnelsBytesWithoutInterpretingTLS() async throws {
        let server = try LoopbackServer { fd, request in LoopbackServer.write(fd, request) }
        defer { server.stop() }
        let relay = try BrowserRelay(
            network: NetworkSnapshot(interface: "lo0"),
            portalURL: URL(string: "https://127.0.0.1:\(server.port)/")!)
        let configuration = try await relay.start()
        let connection = try ScopedConnection(
            host: "127.0.0.1", port: configuration.port, interface: nil,
            deadline: Date().addingTimeInterval(3))
        defer {
            connection.close()
            Task { await relay.stop() }
        }
        try await connection.open()
        let auth = Data(configuration.credential.utf8).base64EncodedString()
        try await connection.send(
            Data(
                "CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n"
                    .utf8))
        let response = try await connection.receive()
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200"))
        let payload = "opaque encrypted bytes\r\n\r\n"
        try await connection.send(Data(payload.utf8))
        let echo = try await connection.receive()
        XCTAssertEqual(String(decoding: echo, as: UTF8.self), payload)
        let count = relay.connections
        XCTAssertEqual(count, 1)
        await relay.stop()
    }

    func testNativeScopedUDPDNSFallbackAndCache() async throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var receiveTimeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            fd, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }, 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let task = Task.detached {
            var bytes = [UInt8](repeating: 0, count: 4096)
            var peer = sockaddr_storage()
            var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &peer) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &bytes, bytes.count, 0, $0, &peerLength)
                }
            }
            guard count >= 12 else { return }
            var answer = Data(bytes.prefix(count))
            answer[2] = 0x81
            answer[3] = 0x80
            answer[6] = 0
            answer[7] = 1
            answer.append(contentsOf: [0xc0, 0x0c, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 10, 0, 0, 1])
            _ = answer.withUnsafeBytes { data in
                withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, data.baseAddress, data.count, 0, $0, peerLength)
                    }
                }
            }
        }
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "lo0"), servers: ["127.0.0.1"], dnsPort: port)
        let result = try await resolver.fallback(
            "portal.test", deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(result, ["10.0.0.1"])
        await task.value
        let cached = try await resolver.fallback(
            "portal.test", deadline: Date().addingTimeInterval(0.01))
        XCTAssertEqual(cached, result)
    }
    func testRelayRejectsDNSRebindingBeforeConnecting() async throws {
        let relay = try BrowserRelay(
            network: NetworkSnapshot(interface: "lo0"),
            portalURL: URL(string: "https://portal.test/")!, resolveHost: { _, _ in ["127.0.0.1"] })
        let config = try await relay.start()
        defer { Task { await relay.stop() } }
        let local = try ScopedConnection(
            host: "127.0.0.1", port: config.port, interface: nil,
            deadline: Date().addingTimeInterval(2))
        defer { local.close() }
        try await local.open()
        let auth = Data(config.credential.utf8).base64EncodedString()
        try await local.send(
            Data(
                "CONNECT evil.test:443 HTTP/1.1\r\nProxy-Authorization: Basic \(auth)\r\n\r\n".utf8)
        )
        let response = try await local.receive()
        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 502"))
        let connections = relay.connections
        XCTAssertEqual(connections, 0)
        await relay.stop()
    }
    func testDiscoveryAndDiagnosticsBoundariesAndRepeatedRecord() async throws {
        let good =
            "https://wifi.wireless-social.com/login/fortinet/fortigate?post=http%3A%2F%2F10.0.0.1%3A1000%2Ffgtauth&magic=abcdef1234"
        XCTAssertNotNil(
            CaptivePortalDiscovery.extract(logText: "URL: \(good)", gatewayIP: "10.0.0.1"))
        XCTAssertNil(CaptivePortalDiscovery.extract(logText: "URL: \(good)", gatewayIP: "10.0.0.2"))
        XCTAssertNil(
            NetworkDiagnostics.portalRedirect(
                from: URL(string: "http://10.0.0.1/")!, location: "/login", gateway: "10.0.0.1"))
        XCTAssertNotNil(
            NetworkDiagnostics.portalRedirect(
                from: URL(string: "http://1.1.1.1/")!, location: "https://portal.test/login",
                gateway: "10.0.0.1"))
        let stub = StubClient([])
        let diagnosis = await NetworkDiagnostics(
            client: stub, network: NetworkSnapshot(interface: "en0"), commands: StubCommands()
        ).diagnose()
        XCTAssertEqual(diagnosis.evidence["reason"] as? String, "address_unavailable")
        let previousData = Data(
            #"{"fingerprint":"x","reason":"address_unavailable","checked_at":10,"first_seen_at":10,"consecutive_checks":1}"#
                .utf8)
        let previous = try JSONSerialization.jsonObject(with: previousData) as! [String: Any]
        let recorded = NetworkDiagnostics.record(
            diagnosis, previous: previous, fingerprint: "x", now: 30)
        XCTAssertEqual(recorded["consecutive_checks"] as? Int, 2)
        XCTAssertEqual(recorded["repeated"] as? Bool, true)
    }
    func testProbeOutcomeMatrix() async {
        let apple = ConnectivityProbe.appleURL
        let google = ConnectivityProbe.googleURL
        let successfulApple = HTTPResponse(url: apple, status: 200, body: Data("Success".utf8))
        let successfulGoogle = HTTPResponse(url: google, status: 204)
        let cases: [([Result<HTTPResponse, Error>], Bool, Bool, ProbeState, String)] = [
            ([.success(successfulApple)], false, false, .online, "apple"),
            (
                [.success(successfulApple), .success(successfulGoogle)], true, true, .online,
                "apple+gstatic"
            ),
            (
                [.success(successfulApple), .failure(NativeNetworkError.timeout)], true, false,
                .captive, "macos-captive-state"
            ),
            (
                [.success(successfulApple), .failure(NativeNetworkError.timeout)], false, true,
                .captive, "connectivity-consensus"
            ),
            (
                [.failure(NativeNetworkError.dnsFailure), .success(successfulGoogle)], false, false,
                .online, "gstatic"
            ),
            (
                [.failure(NativeNetworkError.dnsFailure), .success(successfulGoogle)], true, false,
                .captive, "macos-captive-state"
            ),
            (
                [.failure(NativeNetworkError.timeout), .failure(NativeNetworkError.timeout)], false,
                false, .noNetwork, ""
            ),
            (
                [.failure(NativeNetworkError.timeout), .failure(NativeNetworkError.timeout)], true,
                false, .captive, "macos-captive-state"
            ),
            (
                [
                    .success(
                        HTTPResponse(
                            url: apple, status: 200, body: Data("Success".utf8), truncated: true))
                ], false, false, .captive, "apple"
            ),
            (
                [.success(HTTPResponse(url: apple, status: 404, body: Data("Success".utf8)))],
                false, false, .captive, "apple"
            ),
        ]
        for (responses, hint, consensus, state, source) in cases {
            let result = await ConnectivityProbe(client: StubClient(responses)).check(
                captiveHint: hint, requireConsensus: consensus)
            XCTAssertEqual(result.state, state)
            XCTAssertEqual(result.source, source)
        }
    }
    func testMalformedWireResponsesAreBoundedFailures() async throws {
        let responses = [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZZ\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1770\r\n"
                + String(repeating: "a", count: 6_000) + "\r\n1;"
                + String(repeating: "x", count: 1_024) + "\r\nb\r\n0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nContent-Length: 9\r\n\r\nabcde",
            "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc",
            "HTTP/1.1 200 OK\r\nX-Long: " + String(repeating: "a", count: 17_000) + "\r\n\r\n",
            "HTTP/1.1 302 Found\r\nLocation: javascript:alert(1)\r\nContent-Length: 0\r\n\r\n",
        ]
        for wire in responses {
            let server = try LoopbackServer { fd, _ in LoopbackServer.write(fd, wire) }
            defer { server.stop() }
            do {
                _ = try await NativeHTTPClient(network: NetworkSnapshot(interface: "lo0")).send(
                    HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 1))
                XCTFail("Accepted malformed response")
            } catch {}
        }
    }
    func testInspectionKeepsEthernetForDormancyAndCaptiveRules() async {
        let hardware = "Hardware Port: Wi-Fi\nDevice: en0\n"
        let commands = StubCommands(values: [
            "/usr/sbin/networksetup -listallhardwareports": hardware,
            "/sbin/route -n get default": "interface: en5\ngateway: 192.168.4.1\n",
            "/sbin/route -n get -ifscope en5 default": "interface: en5\ngateway: 192.168.4.1\n",
        ])
        let wired = await NativeNetworkInspector(commands: commands, captiveStatus: { _ in nil })
            .current()
        XCTAssertEqual(wired.interface, "en5")
        XCTAssertEqual(wired.wifiInterfaces, ["en0"])
        let wifi = StubCommands(values: [
            "/usr/sbin/networksetup -listallhardwareports": hardware,
            "/sbin/route -n get default": "interface: en5\n",
            "/usr/sbin/ipconfig getifaddr en0": "10.0.0.4\n",
            "/sbin/route -n get -ifscope en0 default": "interface: en0\ngateway: 10.0.0.1\n",
            "/usr/sbin/ipconfig getsummary en0": "SSID : <redacted>\n",
            "/usr/sbin/arp -n 10.0.0.1": "? (10.0.0.1) at 1:2:3:a:b:c on en0",
        ])
        for (stage, waiting, expected) in [
            ("Evaluate", false, false), ("Unknown", false, false), ("WebSheet", false, true),
            ("Evaluate", true, true),
        ] {
            let snapshot = await NativeNetworkInspector(
                commands: wifi,
                captiveStatus: { _ in CaptiveNetworkRecord(stage: stage, waitingOnUI: waiting) }
            ).current()
            XCTAssertEqual(snapshot.interface, "en0")
            XCTAssertEqual(snapshot.gatewayIP, "10.0.0.1")
            XCTAssertEqual(snapshot.gatewayMAC, "01:02:03:0a:0b:0c")
            XCTAssertNil(snapshot.ssid)
            XCTAssertEqual(snapshot.captiveHint, expected)
        }
    }
    func testNativeFixtureServerValidatesRegistrationAndIndependentGrant() async throws {
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.lastPathComponent != "CuppaAutologinApp" && root.path != "/" {
            root.deleteLastPathComponent()
        }
        let candidates =
            [ProcessInfo.processInfo.environment["CUPPA_FIXTURE_SERVER"]]
            .compactMap { $0 }.map { URL(fileURLWithPath: $0) } + [
                root.appendingPathComponent(".build/debug/CuppaFixtureServer"),
                root.appendingPathComponent(".build/out/Products/Debug/CuppaFixtureServer"),
            ]
        let binary = try XCTUnwrap(
            candidates.first {
                FileManager.default.isExecutableFile(atPath: $0.path)
            }, "Run make native-test to build the required Swift fixture server")
        let ready = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let process = Process()
        process.executableURL = binary
        process.arguments = [ready.path, root.appendingPathComponent("Tests/fixtures").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: ready)
        }
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: ready.path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let base = try String(contentsOf: ready, encoding: .utf8)
        let client = NativeHTTPClient(network: NetworkSnapshot(interface: "lo0"))
        func get(_ path: String) async throws -> HTTPResponse {
            try await client.send(
                HTTPRequest(url: URL(string: base + path)!, followRedirects: false))
        }
        func csrf(_ response: HTTPResponse) -> String {
            response.text.components(separatedBy: "name=\"csrf\" type=\"hidden\" value=\"")
                .dropFirst().first?.components(separatedBy: "\"").first ?? ""
        }
        func post(_ path: String, _ fields: [String: String]) async throws -> HTTPResponse {
            var components = URLComponents()
            components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
            return try await client.send(
                HTTPRequest(
                    url: URL(string: base + path)!, method: "POST",
                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                    body: Data((components.percentEncodedQuery ?? "").utf8), followRedirects: false)
            )
        }
        let initial = try await get("/vision/account-create")
        let token = csrf(initial)
        XCTAssertFalse(token.isEmpty)
        let before = try await get("/vision/access-check")
        XCTAssertTrue(before.text.contains("\"online\":false"))
        let rejected = try await post("/vision/signup", ["csrf": "wrong"])
        XCTAssertEqual(rejected.status, 403)
        let invalid = try await post("/vision/signup", ["csrf": token])
        XCTAssertEqual(invalid.status, 422)
        let password = "Local-fixture-password-42!"
        let email = "sarah.chen.wifi@gmail.com"
        let signup = try await post(
            "/vision/signup",
            [
                "csrf": token, "user[name]": "Sarah Chen", "user[email]": email,
                "user[email_confirmation]": email, "user[password]": password,
                "user[password_confirmation]": password,
            ])
        XCTAssertEqual(signup.status, 303)
        let login = try await get("/vision/login")
        let next = csrf(login)
        XCTAssertNotEqual(next, token)
        let missingTerms = try await post(
            "/vision/login", ["csrf": next, "email": email, "password": password])
        XCTAssertEqual(missingTerms.status, 422)
        let grant = try await post(
            "/vision/login", ["csrf": next, "email": email, "password": password, "terms": "1"])
        XCTAssertEqual(grant.status, 303)
        let after = try await get("/vision/access-check")
        let result = try JSONSerialization.jsonObject(with: after.body) as! [String: Any]
        XCTAssertEqual(result["online"] as? Bool, true)
        XCTAssertEqual(result["actions"] as? [String], ["signup", "login"])
        let returning = try await get("/vision/account-return")
        let returningToken = csrf(returning)
        let reRegister = try await post("/vision/signup", ["csrf": returningToken])
        XCTAssertEqual(reRegister.status, 409)
        let returnedGrant = try await post(
            "/vision/login",
            ["csrf": returningToken, "email": email, "password": password, "terms": "1"])
        XCTAssertEqual(returnedGrant.status, 303)
        let returnedCheck = try await get("/vision/access-check")
        let returned = try JSONSerialization.jsonObject(with: returnedCheck.body) as! [String: Any]
        XCTAssertEqual(returned["actions"] as? [String], ["login"])
    }

    func testNativeTLSRejectsUntrustedPeerBeforeHTTPRequest() async throws {
        // This untrusted self-signed identity exists only in this isolated loopback fixture.
        let pkcs12 = Data(
            base64Encoded:
                "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"
        )!
        guard #available(macOS 15, *) else {
            throw XCTSkip("Memory-only test identity import requires macOS 15")
        }
        var imported: CFArray?
        XCTAssertEqual(
            SecPKCS12Import(
                pkcs12 as CFData,
                [
                    kSecImportExportPassphrase as String: "fixture",
                    kSecImportToMemoryOnly as String: true,
                ] as CFDictionary, &imported), errSecSuccess)
        let entries = imported as! [[String: Any]]
        let identity = entries[0][kSecImportItemIdentity as String] as! SecIdentity
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(
            tls.securityProtocolOptions, sec_identity_create(identity)!)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let queue = DispatchQueue(label: "CuppaNetworkingTests.tls")
        let bytes = ReceivedBytes()
        listener.newConnectionHandler = { connection in
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                        data, _, _, _ in
                        bytes.add(data?.count ?? 0)
                        connection.send(
                            content: Data(
                                "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecure".utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
            connection.start(queue: queue)
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let box = Completion(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: box.finish(.success(()))
                case .failed(let error): box.finish(.failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        let client = NativeHTTPClient(network: NetworkSnapshot())
        do {
            _ = try await client.send(
                HTTPRequest(
                    url: URL(string: "https://localhost:\(listener.port!.rawValue)/secret")!,
                    headers: ["Authorization": "fixture-only-secret"], timeout: 10))
            XCTFail("Untrusted TLS peer accepted")
        } catch {
            guard let native = error as? NWError, case .tls = native else {
                XCTFail("Expected TLS trust rejection, got \(error)")
                return
            }
        }
        XCTAssertEqual(bytes.count, 0)
        var certificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
        let anchor = SecCertificateCopyData(try XCTUnwrap(certificate)) as Data
        let trusted = NativeHTTPClient(
            network: NetworkSnapshot(interface: "lo0"), trustAnchors: [anchor])
        let secure = try await trusted.send(
            HTTPRequest(
                url: URL(string: "https://localhost:\(listener.port!.rawValue)/secure")!, timeout: 4
            ))
        XCTAssertEqual(secure.status, 200)
        XCTAssertEqual(secure.text, "secure")
        let acceptedBytes = bytes.count
        do {
            _ = try await trusted.send(
                HTTPRequest(
                    url: URL(string: "https://127.0.0.1:\(listener.port!.rawValue)/wrong-name")!,
                    timeout: 4))
            XCTFail("Trusted anchor bypassed hostname validation")
        } catch {
            guard let native = error as? NWError, case .tls = native else {
                return XCTFail("Expected hostname TLS error: \(error)")
            }
        }
        XCTAssertEqual(bytes.count, acceptedBytes)
    }

    func testDNSDiagnosticMatrixRecordsEveryServerAndSkipsRepeatedTimeouts() async throws {
        let calls = DNSCalls()
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "en0", gatewayIP: "10.0.0.1"),
            servers: ["10.0.0.2"],
            queryServer: { interface, server, host, type, _ in
                await calls.add(interface: interface, server: server, host: host, type: type)
                if server == "10.0.0.2" { throw NativeNetworkError.timeout }
                return server == "10.0.0.1" ? ["10.0.0.4"] : []
            })
        let matrix = await resolver.diagnosticMatrix(
            hosts: ["portal.test", "portal.test"], deadline: Date().addingTimeInterval(2))
        XCTAssertEqual(matrix.serversTried, ["10.0.0.2", "10.0.0.1", "1.1.1.1"])
        XCTAssertEqual(matrix.serversResponding, ["10.0.0.1"])
        XCTAssertEqual(matrix.queries.count, 10)
        XCTAssertFalse(matrix.deadlineReached)
        XCTAssertEqual(matrix.queries.filter { $0.server == "10.0.0.2" }.count, 2)
        let records = await calls.entries
        XCTAssertTrue(records.allSatisfy { $0.0 == "en0" && $0.3 == 1 })
        XCTAssertEqual(records.count, 10)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: matrix.json))
        let bounded = await resolver.diagnosticMatrix(
            hosts: [], deadline: Date().addingTimeInterval(-1))
        XCTAssertTrue(bounded.deadlineReached)
        XCTAssertTrue(bounded.queries.isEmpty)
    }

}

private final class ReceivedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    func add(_ count: Int) {
        lock.lock()
        received += count
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return received
    }
}

private actor DNSCalls {
    var entries: [(String, String, String, UInt16)] = []
    func add(interface: String, server: String, host: String, type: UInt16) {
        entries.append((interface, server, host, type))
    }
}

private actor LiteralFixtureClient: HTTPClient {
    let native = NativeHTTPClient(network: NetworkSnapshot(interface: "lo0"))
    let port: UInt16
    init(port: UInt16) { self.port = port }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var local = request
        local.url = URL(string: "http://127.0.0.1:\(port)/")!
        return try await native.send(local)
    }
}
extension NetworkingTests {
    func testRealLiteralHTTPDiagnosticRedirectAvoidsDNSAndCookies() async throws {
        let server = try LoopbackServer { fd, _ in
            LoopbackServer.write(
                fd,
                "HTTP/1.1 302 Found\r\nLocation: https://portal.example/splash?token=fixture-secret\r\nSet-Cookie: saved=private; Path=/\r\nContent-Length: 0\r\n\r\n"
            )
        }
        defer { server.stop() }
        let commands = StubCommands(values: ["/usr/sbin/ipconfig getifaddr lo0": "10.0.0.42"])
        let result = await NetworkDiagnostics(
            client: LiteralFixtureClient(port: server.port),
            network: NetworkSnapshot(interface: "lo0", gatewayIP: "10.0.0.1"), commands: commands
        ).diagnose()
        XCTAssertEqual(
            result.portalURL?.absoluteString, "https://portal.example/splash?token=fixture-secret")
        XCTAssertEqual(result.evidence["reason"] as? String, "portal_discovered")
        XCTAssertFalse(String(describing: result.evidence).contains("fixture-secret"))
        let requests = server.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(
            requests.allSatisfy { $0.hasPrefix("GET / HTTP/1.1") && !$0.contains("saved=private") })
    }
    func testDribblingHTTPHeadersCannotExtendAbsoluteDeadlineAndSocketCloses() async throws {
        let bytes = ReceivedBytes()
        let server = try LoopbackServer { fd, _ in
            var noSignal: Int32 = 1
            _ = setsockopt(
                fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            for value in Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8) {
                // A graceful FIN is observable on receive even while the peer's
                // kernel still accepts buffered writes. Test closure itself,
                // rather than assuming send must fail within a fixed 200 ms.
                var probe: UInt8 = 0
                let received = recv(fd, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
                if received == 0 || (received < 0 && errno == ECONNRESET) {
                    bytes.add(1)
                    return
                }
                var byte = value
                if send(fd, &byte, 1, 0) <= 0 {
                    bytes.add(1)
                    return
                }
                Thread.sleep(forTimeInterval: 0.04)
            }
        }
        defer { server.stop() }
        let start = Date()
        do {
            _ = try await NativeHTTPClient(network: NetworkSnapshot(interface: "lo0")).send(
                HTTPRequest(
                    url: URL(string: "http://127.0.0.1:\(server.port)/")!, timeout: 0.25,
                    maximumBodyBytes: 0))
            XCTFail("Dribbling peer extended deadline")
        } catch {
            XCTAssertEqual(ConnectivityProbe.errorCategory(error), "request_timeout")
            XCTAssertEqual((error as? HTTPTransportError)?.connected, true)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.8)
        let closeDeadline = Date().addingTimeInterval(2)
        while bytes.count == 0 && Date() < closeDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(bytes.count, 1, "Timed out native connection must close peer socket")
    }
}
extension NetworkingTests {
    func testNativeHTTPRedirectKeepsMixedRawSpaceAndEncodedCallback() async throws {
        let server = try LoopbackServer { fd, request in
            if request.hasPrefix("GET /start ") {
                LoopbackServer.write(
                    fd,
                    "HTTP/1.1 302 Found\r\nLocation: /login?ssid=Guest WiFi&callback=http%3A%2F%2F10.0.0.1%2F&mac=aa:bb\r\nContent-Length: 0\r\n\r\n"
                )
            } else {
                LoopbackServer.write(fd, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n")
            }
        }
        defer { server.stop() }
        let response = try await NativeHTTPClient(network: NetworkSnapshot(interface: "lo0")).send(
            HTTPRequest(url: URL(string: "http://127.0.0.1:\(server.port)/start")!, timeout: 3))
        XCTAssertEqual(response.status, 200)
        XCTAssertTrue(
            response.url.absoluteString.contains(
                "ssid=Guest%20WiFi&callback=http%3A%2F%2F10.0.0.1%2F&mac=aa:bb"))
        let requests = server.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(
            requests.last!.hasPrefix(
                "GET /login?ssid=Guest%20WiFi&callback=http%3A%2F%2F10.0.0.1%2F&mac=aa:bb HTTP/1.1")
        )
        XCTAssertFalse(requests.last!.contains("%253A"))
    }
}

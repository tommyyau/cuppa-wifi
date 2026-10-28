import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

private struct SyntheticForensicCommands: SystemCommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async
        -> CommandOutput
    {
        CommandOutput(status: 0, text: "Synthetic command fixture")
    }
}
private struct DisconnectedWiFiCommands: SystemCommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async
        -> CommandOutput
    {
        let text: String
        if executable.hasSuffix("networksetup") {
            text = "Hardware Port: Wi-Fi\nDevice: en0\nHardware Port: Ethernet\nDevice: en5\n"
        } else if executable.hasSuffix("route") {
            text = "interface: en5\ngateway: 192.0.2.1\n"
        } else if executable.hasSuffix("ifconfig") {
            text = "status: inactive\n"
        } else {
            text = ""
        }
        return CommandOutput(status: 0, text: text)
    }
}
private actor SyntheticForensicHTTP: HTTPClient {
    var requests: [HTTPRequest] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url.host != "portal.example" {
            return HTTPResponse(
                url: request.url, status: 302,
                headers: ["Location": "https://portal.example/bridge"])
        }
        let body: String
        switch request.url.path {
        case "/bridge": body = "<script>window.location.href='/app';</script>"
        case "/app":
            body =
                "<title>Synthetic Portal</title><div id='app'></div><script src='/boot.js'></script>"
        case "/boot.js": body = "console.log('synthetic fixture');"
        default: throw URLError(.unsupportedURL)
        }
        return HTTPResponse(url: request.url, status: 200, body: Data(body.utf8))
    }
    func observed() -> [HTTPRequest] { requests }
}
private actor PurpleShimHTTP: HTTPClient {
    var requests: [HTTPRequest] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        let marked =
            URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "jsrd" && $0.value == "1"
            } == true
        let body =
            marked
            ? "<title>Synthetic Purple</title><div id='app'></div><script>boot()</script>"
            : "<script>var query=location.search; query += '&jsrd=1'; window.location.href=location.pathname + query;</script>"
        return HTTPResponse(url: request.url, status: 200, body: Data(body.utf8))
    }
    func observed() -> [HTTPRequest] { requests }
}

final class AncillaryContractTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var paths: EnginePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-cli-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func testReadOnlyStatusAndStatsDoNotCreateDataDirectory() async throws {
        let status = await EngineCLI.execute(arguments: ["--status"], paths: paths, resources: root)
        let stats = await EngineCLI.execute(
            arguments: ["--portal-stats"], paths: paths, resources: root)
        XCTAssertEqual(status.status, 0)
        XCTAssertEqual(stats.status, 0)
        XCTAssertTrue(status.output.contains("UNKNOWN"))
        XCTAssertTrue(stats.output.contains("automatic_verified"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testDisconnectedWiFiRetainsEthernetRouteForDormancy() async {
        let inspector = NativeNetworkInspector(
            commands: DisconnectedWiFiCommands(), captiveStatus: { _ in nil })
        let snapshot = await inspector.current()
        XCTAssertEqual(snapshot.interface, "en5")
        XCTAssertEqual(snapshot.wifiInterfaces, ["en0"])
        XCTAssertFalse(snapshot.captiveHint)
        XCTAssertEqual(
            NetworkIdentity.dormancy(
                network: snapshot, identity: PortalIdentity(values: [:]), ignoreText: ""),
            "non_wifi")
    }
    func testInstallCheckRejectsInvalidIdentityWithoutEchoingValues() async throws {
        try PrivateFile.write(Data("SENTINEL_SECRET_WITHOUT_EQUALS".utf8), to: paths.identity)
        let result = await EngineCLI.execute(
            arguments: ["--install-check"], paths: paths, resources: root)
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse((result.output + result.error).contains("SENTINEL"))
    }
    func testTriageEmptyAndUnknownCommandsStayReadOnly() async throws {
        let result = await EngineCLI.execute(arguments: ["--triage"], paths: paths, resources: root)
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("No captured venues"))
        let unknown = await EngineCLI.execute(
            arguments: ["--invented"], paths: paths, resources: root)
        XCTAssertEqual(unknown.status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testForensicRateLimitUsesPrivateMarkerAndRejectsFutureTime() throws {
        let recorder = ForensicRecorder(paths: paths)
        XCTAssertTrue(recorder.shouldRun(fingerprint: "venue", now: 1000))
        let marker = paths.forensics.appendingPathComponent("venue/last_sweep_ts")
        try PrivateFile.write(Data("1000".utf8), to: marker)
        XCTAssertFalse(recorder.shouldRun(fingerprint: "venue", now: 999))
        XCTAssertFalse(recorder.shouldRun(fingerprint: "venue", now: 1899))
        XCTAssertTrue(recorder.shouldRun(fingerprint: "venue", now: 1900))
        XCTAssertFalse(recorder.shouldRun(fingerprint: "", now: 1900))
    }
    func testForensicHTMLAnalysisDistinguishesStaticFromRenderedShell() {
        XCTAssertEqual(
            ForensicRecorder.analyze("<form><input name='email'></form><script>boot()</script>")[
                "looks_js_rendered"] as? Bool, false)
        XCTAssertEqual(
            ForensicRecorder.analyze("<div id='app'></div><script src='/boot.js'></script>")[
                "looks_js_rendered"] as? Bool, true)
    }
    func testForensicSweepDiscoversJSJourneyWithOnlyInjectedIO() async throws {
        let recorder = ForensicRecorder(
            paths: paths, commands: SyntheticForensicCommands(),
            resolveHost: { _, _ in ["192.0.2.2"] })
        let http = SyntheticForensicHTTP()
        let network = NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest")
        let recorded = await recorder.run(network: network, client: http, now: 1000)
        let directory = try XCTUnwrap(recorded)
        let summary = try XCTUnwrap(
            PrivateFile.object(at: directory.appendingPathComponent("summary.json")))
        XCTAssertEqual(summary["portal_final_url"] as? String, "https://portal.example/app")
        XCTAssertEqual(
            (summary["portal_final_analysis"] as? [String: Any])?["looks_js_rendered"] as? Bool,
            true)
        XCTAssertEqual(summary["portal_chain_hops"] as? Int, 2)
        XCTAssertFalse(recorder.shouldRun(fingerprint: network.gatewayMAC!, now: 1899))
        let requests = await http.observed()
        XCTAssertTrue(requests.contains { $0.url.path == "/boot.js" })
        XCTAssertTrue(requests.allSatisfy { !$0.followRedirects && $0.maximumBodyBytes <= 524_288 })
        for item in [directory, directory.deletingLastPathComponent()] {
            let attributes = try FileManager.default.attributesOfItem(atPath: item.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
    }
    func testPurpleReviewedShimPreservesQueryAndDoesNotLoop() async throws {
        let recorder = ForensicRecorder(
            paths: paths, commands: SyntheticForensicCommands(),
            resolveHost: { _, _ in ["192.0.2.2"] })
        let client = PurpleShimHTTP()
        let recorded = await recorder.run(
            network: NetworkSnapshot(interface: "en0", gatewayMAC: "02:00:00:00:00:01"),
            client: client,
            portalURL: URL(string: "https://portal.example/access/?ap_mac=synthetic")!, now: 1000)
        let summary = try XCTUnwrap(
            PrivateFile.object(at: try XCTUnwrap(recorded).appendingPathComponent("summary.json")))
        XCTAssertEqual(
            summary["portal_final_url"] as? String,
            "https://portal.example/access/?ap_mac=synthetic&jsrd=1")
        let requests = await client.observed()
        let marked = requests.filter { $0.url.query?.contains("jsrd=1") == true }
        XCTAssertEqual(marked.count, 1)
    }
    func testDNSMatrixPreservesEachResolverFailureAndIndependentSuccess() async {
        let resolver = ScopedDNSResolver(
            network: NetworkSnapshot(interface: "en0", gatewayIP: "192.0.2.1"),
            commands: SyntheticForensicCommands(), servers: ["192.0.2.53"],
            queryServer: { interface, server, _, type, _ in
                XCTAssertEqual(interface, "en0")
                XCTAssertEqual(type, 1)
                if server == "192.0.2.53" { throw URLError(.timedOut) }
                if server == "192.0.2.1" { return [] }
                return ["192.0.2.2"]
            })
        let matrix = await resolver.diagnosticMatrix(
            hosts: ["portal.example", "portal.example"], deadline: Date().addingTimeInterval(5))
        XCTAssertEqual(matrix.serversTried, ["192.0.2.53", "192.0.2.1", "1.1.1.1"])
        XCTAssertEqual(matrix.serversResponding, ["1.1.1.1"])
        XCTAssertFalse(matrix.deadlineReached)
        XCTAssertEqual(
            matrix.queries.filter { $0.server == "192.0.2.53" }.count, 2,
            "Repeated timeouts must be bounded per resolver")
        XCTAssertTrue(
            matrix.queries.filter { $0.server == "192.0.2.53" }.allSatisfy {
                $0.error == "request_timeout"
            })
        XCTAssertEqual(matrix.queries.filter { $0.hostname == "portal.example" }.count, 2)
        XCTAssertTrue(matrix.queries.contains { $0.hostname == "captive.apple.com" })
        XCTAssertTrue(matrix.queries.contains { $0.hostname == "connectivitycheck.gstatic.com" })
        XCTAssertTrue(matrix.queries.contains { $0.hostname == "purpleportal.net" })
        XCTAssertTrue(matrix.queries.allSatisfy { $0.elapsedMilliseconds >= 0 })
    }
    func testForensicSweepPersistsDNSMatrixWithoutRealResolution() async throws {
        let recorder = ForensicRecorder(
            paths: paths, commands: SyntheticForensicCommands(),
            resolveHost: { _, _ in ["192.0.2.2"] })
        let recorded = await recorder.run(
            network: NetworkSnapshot(
                interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01"),
            client: SyntheticForensicHTTP(),
            portalURL: URL(string: "https://portal.example/bridge")!, now: 1000)
        let matrix = try XCTUnwrap(
            PrivateFile.object(
                at: try XCTUnwrap(recorded).appendingPathComponent("dns_matrix.json")))
        XCTAssertEqual(matrix["servers_tried"] as? [String], ["192.0.2.1", "1.1.1.1"])
        let queries = try XCTUnwrap(matrix["queries"] as? [[String: Any]])
        XCTAssertEqual(queries.count, 8)
        XCTAssertEqual(
            Set(queries.compactMap { $0["hostname"] as? String }),
            Set([
                "captive.apple.com", "connectivitycheck.gstatic.com", "purpleportal.net",
                "portal.example",
            ]))
        XCTAssertTrue(queries.allSatisfy { $0["addresses"] as? [String] == ["192.0.2.2"] })
    }
    private func triageFixture() throws {
        let venue = paths.captures.appendingPathComponent("02_00_00_00_00_08/20000101T155714Z")
        try PrivateFile.writeJSON(
            ["failure_reason": "persona_phone_rejected"],
            to: venue.appendingPathComponent("diagnostic.json"))
        try PrivateFile.writeJSON(
            [["method": "GET", "url": "http://192.0.2.1/login", "status": 200]],
            to: venue.appendingPathComponent("manifest.json"))
        try PrivateFile.write(
            Data("{\"success\":false,\"message\":\"This value is not valid phone number.\"}".utf8),
            to: venue.appendingPathComponent("04_body.html"))
        try PrivateFile.writeJSON(
            ["failure_reason": "privacy_email_required"],
            to: paths.captures.appendingPathComponent(
                "aa_bb_cc_dd_ee_ff/20000101T090000Z/diagnostic.json"))
        try PrivateFile.write(
            Data(
                "2000-01-01 INFO portal venue identified: Synthetic Cafe\n2000-01-01 WARNING login failed (1), captured to /x/captures/02_00_00_00_00_08/20000101T155714Z\n2000-01-01 INFO unrelated line\n"
                    .utf8), to: paths.log)
    }
    func testTriageTimelineIncludesBothVenuesAndReasons() throws {
        try triageFixture()
        let output = TriageReport(paths: paths).render(selector: nil)
        XCTAssertTrue(output.contains("02_00_00_00_00_08"))
        XCTAssertTrue(output.contains("aa_bb_cc_dd_ee_ff"))
        XCTAssertTrue(output.contains("persona_phone_rejected"))
        XCTAssertTrue(output.contains("privacy_email_required"))
        if let newer = output.range(of: "02_00_00_00_00_08"),
            let older = output.range(of: "aa_bb_cc_dd_ee_ff")
        {
            XCTAssertLessThan(newer.lowerBound, older.lowerBound)
        }
    }
    func testTriageVenueNameResolvesLogAndIncludesPrivateServerExplanation() throws {
        try triageFixture()
        let output = TriageReport(paths: paths).render(selector: "synthetic cafe")
        XCTAssertTrue(output.contains("02_00_00_00_00_08"))
        XCTAssertTrue(output.contains("persona_phone_rejected"))
        XCTAssertTrue(output.contains("not valid phone number"))
        XCTAssertFalse(output.contains("unrelated line"))
    }
}

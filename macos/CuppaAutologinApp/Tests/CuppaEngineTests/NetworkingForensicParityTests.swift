import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

private struct ForensicParityCommands: SystemCommandRunning {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandOutput {
        CommandOutput(status: 0, text: "fixture output")
    }
}
private actor ForensicParityHTTP: HTTPClient {
    let routes: [String: HTTPResponse]
    var seen: [HTTPRequest] = []
    init(_ routes: [String: HTTPResponse]) { self.routes = routes }
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        seen.append(request)
        guard let response = routes[request.url.absoluteString] else {
            throw NativeNetworkError.timeout
        }
        return response
    }
    func requests() -> [HTTPRequest] { seen }
}
final class NetworkingForensicParityTests: XCTestCase, @unchecked Sendable {
    private let network = NetworkSnapshot(
        interface: "en0", gatewayIP: "10.0.0.1", gatewayMAC: "98:18:88:00:00:01", ssid: "Fixture")
    private func paths() throws -> EnginePaths {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "forensic-parity-" + UUID().uuidString)
        return EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
    }
    private func response(
        _ url: String, _ body: String = "", status: Int = 200, location: String? = nil
    ) -> HTTPResponse {
        HTTPResponse(
            url: URL(string: url)!, status: status,
            headers: location.map { ["Location": $0] } ?? [:], body: Data(body.utf8))
    }
    private func run(_ routes: [String: HTTPResponse], portal: String? = nil) async throws -> (
        URL, [String: Any], [[String: Any]], ForensicParityHTTP
    ) {
        let paths = try paths()
        let client = ForensicParityHTTP(routes)
        let recorder = ForensicRecorder(
            paths: paths, commands: ForensicParityCommands(),
            resolveHost: { _, _ in throw NativeNetworkError.timeout })
        let result = await recorder.run(
            network: network, client: client, portalURL: portal.flatMap(URL.init(string:)),
            now: 1000)
        let directory = try XCTUnwrap(result)
        let summary = try XCTUnwrap(
            PrivateFile.object(at: directory.appendingPathComponent("summary.json")))
        let chain =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("portal_chain.json")))
            as! [[String: Any]]
        addTeardownBlock { try? FileManager.default.removeItem(at: paths.root) }
        return (directory, summary, chain, client)
    }
    func testForensicFirstSweepRateLimitExactBoundaryAndNoFingerprint() throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let recorder = ForensicRecorder(paths: paths)
        XCTAssertTrue(recorder.shouldRun(fingerprint: "pret-gateway", now: 1000))
        XCTAssertFalse(recorder.shouldRun(fingerprint: ""))
        let marker = paths.forensics.appendingPathComponent("pret-gateway/last_sweep_ts")
        try PrivateFile.write(Data("1000".utf8), to: marker)
        XCTAssertFalse(recorder.shouldRun(fingerprint: "pret-gateway", now: 1899))
        XCTAssertTrue(recorder.shouldRun(fingerprint: "pret-gateway", now: 1900))
    }
    func testForensicStaticFormAndScriptShellAnalysis() {
        let form = ForensicRecorder.analyze(
            "<title>Guest WiFi</title><form><input name='email'></form>")
        XCTAssertEqual(form["title"] as? String, "Guest WiFi")
        XCTAssertEqual(form["forms"] as? Int, 1)
        XCTAssertEqual(form["inputs"] as? Int, 1)
        XCTAssertEqual(form["looks_js_rendered"] as? Bool, false)
        let shell = ForensicRecorder.analyze(
            "<html><body><script src='/app.js'></script></body></html>")
        XCTAssertEqual(shell["forms"] as? Int, 0)
        XCTAssertEqual(shell["looks_js_rendered"] as? Bool, true)
    }
    func testForensicCrossHostInterceptionCapturesScriptsAndPrivateBodyDespiteDeadDNS() async throws
    {
        let portal = "https://portal.example/splash"
        let script = "https://portal.example/bundle.js"
        let (directory, summary, chain, client) = try await run([
            "http://1.1.1.1/": response("http://1.1.1.1/", status: 302, location: portal),
            portal: response(portal, "<title>Pret WiFi</title><script src='\(script)'></script>"),
            script: response(script, "renderForm();"),
        ])
        XCTAssertEqual(summary["dns_servers_responding"] as? [String], [])
        XCTAssertEqual(summary["http_intercepted_to"] as? String, portal)
        XCTAssertEqual(summary["portal_final_url"] as? String, portal)
        XCTAssertEqual(
            (summary["portal_final_analysis"] as? [String: Any])?["looks_js_rendered"] as? Bool,
            true)
        XCTAssertEqual(chain.count, 1)
        let index =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: directory.appendingPathComponent("portal/scripts/index.json")))
            as! [[String: Any]]
        XCTAssertEqual(index.first?["url"] as? String, script)
        let mode =
            try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent("portal/01_body.html").path)[
                .posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let requests = await client.requests()
        XCTAssertTrue(requests.allSatisfy { !$0.followRedirects && $0.maximumBodyBytes <= 524288 })
    }
    func testForensicSameHostSchemeUpgradeIsNotInterception() async throws {
        let (_, summary, chain, _) = try await run([
            "http://1.1.1.1/": response(
                "http://1.1.1.1/", status: 302, location: "https://1.1.1.1/")
        ])
        XCTAssertNil(summary["http_intercepted_to"] as? String)
        XCTAssertEqual(chain.count, 0)
    }
    func testForensicMissingLocationAndEverythingDeadStillWriteSummary() async throws {
        let (_, summary, chain, _) = try await run([:])
        XCTAssertEqual(summary["portal_chain_hops"] as? Int, 0)
        XCTAssertEqual(chain.count, 0)
        XCTAssertNil(summary["http_intercepted_to"] as? String)
        XCTAssertTrue(
            (summary["notes"] as? [String] ?? []).contains {
                $0.contains("No portal URL discovered")
            })
        let (_, withoutLocation, noChain, _) = try await run([
            "http://1.1.1.1/": response("http://1.1.1.1/", status: 302)
        ])
        XCTAssertNil(withoutLocation["http_intercepted_to"] as? String)
        XCTAssertEqual(noChain.count, 0)
    }
    func testForensicGatewayHostedLoginFormIsFollowedAndExplained() async throws {
        let gateway = "http://10.0.0.1/"
        let login = gateway + "login"
        let (_, summary, chain, _) = try await run([
            gateway: response(gateway, status: 302, location: login),
            login: response(
                login,
                "<title>Boom WiFi</title><form><input name='email'><input name='name'></form>"),
        ])
        XCTAssertEqual(summary["portal_final_url"] as? String, login)
        XCTAssertEqual((summary["portal_final_analysis"] as? [String: Any])?["forms"] as? Int, 1)
        XCTAssertEqual(
            (summary["portal_final_analysis"] as? [String: Any])?["looks_js_rendered"] as? Bool,
            false)
        XCTAssertEqual(chain.compactMap { $0["url"] as? String }, [login])
        XCTAssertTrue(
            (summary["notes"] as? [String] ?? []).contains {
                $0.contains("gateway serves the portal")
            })
    }
    func testForensicPurpleShimAppendsMarkerPreservesQueryAndStopsLoop() async throws {
        let entry = "https://portal.example/access/?ap_mac=aa"
        let marked = entry + "&jsrd=1"
        let shim =
            "<script>var query = window.location.search.substring(1); if(query){query += '&jsrd=1';} window.location.href = url;</script>"
        let (_, summary, chain, client) = try await run(
            [entry: response(entry, shim), marked: response(marked, shim)], portal: entry)
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain.first?["js_redirect"] as? String, marked)
        XCTAssertEqual(summary["portal_final_url"] as? String, marked)
        let requests = await client.requests()
        XCTAssertEqual(requests.filter { $0.url.absoluteString == marked }.count, 1)
    }
    func testForensicLiteralLocationIsFollowedAndDynamicExpressionIsNot() async throws {
        let entry = "https://portal.example/entry"
        let welcome = "https://portal.example/welcome"
        let (_, summary, chain, _) = try await run(
            [
                entry: response(entry, "<script>window.location.href='/welcome';</script>"),
                welcome: response(welcome, "Welcome"),
            ], portal: entry)
        XCTAssertEqual(summary["portal_final_url"] as? String, welcome)
        XCTAssertEqual(chain.count, 2)
        let (_, dynamic, dynamicChain, client) = try await run(
            [entry: response(entry, "<script>window.location.href=buildUrl();</script>")],
            portal: entry)
        XCTAssertEqual(dynamic["portal_final_url"] as? String, entry)
        XCTAssertEqual(dynamicChain.count, 1)
        let requested = await client.requests()
        XCTAssertFalse(requested.contains { $0.url.absoluteString.contains("buildUrl") })
    }
    func testForensicMarkerAndOldSweepPruningKeepNewestEight() async throws {
        let paths = try paths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let parent = paths.forensics.appendingPathComponent("98_18_88_00_00_01")
        for index in 0..<11 {
            try PrivateFile.directory(
                parent.appendingPathComponent(String(format: "19600101T0000%02dZ", index)))
        }
        let recorder = ForensicRecorder(
            paths: paths, commands: ForensicParityCommands(),
            resolveHost: { _, _ in throw NativeNetworkError.timeout })
        let recorded = await recorder.run(
            network: network, client: ForensicParityHTTP([:]), now: 1000)
        let directory = try XCTUnwrap(recorded)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(remaining.count, 8)
        XCTAssertTrue(remaining.contains { $0.lastPathComponent == directory.lastPathComponent })
        XCTAssertFalse(recorder.shouldRun(fingerprint: network.gatewayMAC!, now: 1001))
    }
}

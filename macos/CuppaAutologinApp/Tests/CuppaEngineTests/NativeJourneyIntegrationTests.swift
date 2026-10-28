import CuppaCore
import CuppaEngine
import CuppaNetworking
import CuppaPortals
import Foundation
import XCTest

/// Owns the acceptance oracle, independently of the production form classifier.
/// Internet access appears only after both expected actions are accepted.
private actor JourneyGrantOracle: HTTPClient, NetworkInspecting {
    var posts: [(String, String)] = []
    var granted = false
    var rejectThenExternalOnline = false
    var probeCount = 0
    var failures: [String] = []
    func rejectRegistration() { rejectThenExternalOnline = true }
    func current() async -> NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Multi Stage", wifiInterfaces: ["en0"])
    }
    func cookies() async -> [PortalCookie] {
        [PortalCookie(name: "journey", value: "synthetic-session", domain: "portal.example")]
    }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        func page(_ body: String) -> HTTPResponse {
            HTTPResponse(url: request.url, status: 200, body: Data(body.utf8))
        }
        if request.url.host == "captive.apple.com" {
            probeCount += 1
            if granted { return page("<html><body>Success</body></html>") }
            return HTTPResponse(
                url: request.url, status: 302, headers: ["Location": "https://portal.example/join"])
        }
        if request.url.host == "connectivitycheck.gstatic.com" {
            probeCount += 1
            return HTTPResponse(
                url: request.url, status: granted ? 204 : 302,
                headers: granted ? [:] : ["Location": "https://portal.example/join"])
        }
        if request.method == "GET", request.url.path == "/join" {
            return page(
                "<form method='post' action='/register'><input required type='email' name='email'><input type='hidden' name='csrf' value='fresh-registration-token'><input required type='checkbox' name='terms' value='accepted'><label>I accept terms</label><button name='join' value='yes'>Connect</button></form>"
            )
        }
        if request.method == "POST" {
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            posts.append((request.url.path, body))
            if rejectThenExternalOnline {
                granted = true
                return page("{\"success\":false,\"message\":\"Identity rejected\"}")
            }
            if request.url.path == "/register", posts.count == 1,
                body.contains("email=synthetic%40example.test"),
                body.contains("csrf=fresh-registration-token"), body.contains("terms=accepted")
            {
                return page(
                    "<form method='post' action='/activate'><input type='hidden' name='csrf' value='fresh-activation-token'><input required type='text' name='first_name' autocomplete='given-name'><button name='activate' value='yes'>Connect</button></form>"
                )
            }
            if request.url.path == "/activate", posts.count == 2,
                body.contains("csrf=fresh-activation-token"), body.contains("first_name=Synthetic"),
                !body.contains("fresh-registration-token")
            {
                granted = true
                return page("<p>Welcome</p>")
            }
            failures.append(request.url.path)
            return HTTPResponse(
                url: request.url, status: 400, body: Data("Rejected by independent oracle".utf8))
        }
        throw URLError(.unsupportedURL)
    }
    func outcome() -> (grant: Bool, paths: [String], probes: Int, errors: [String]) {
        (granted, posts.map(\.0), probeCount, failures)
    }
}

final class NativeJourneyIntegrationTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var paths: EnginePaths!
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macos/Resources")
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-journey-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
        try PrivateFile.write(
            Data(
                "FAKE_FIRST_NAME=Synthetic\nFAKE_LAST_NAME=Guest\nFAKE_EMAIL=synthetic@example.test\nFAKE_DOB=1990-01-01\nFAKE_POSTCODE=SW1A 1AA\nFAKE_PHONE=07700900123\nSIGNUP_PASSWORD=synthetic-password\n"
                    .utf8), to: paths.identity)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func engine(_ oracle: JourneyGrantOracle) -> CuppaEngine {
        let paths = paths!
        let resources = resources
        return CuppaEngine(
            paths: paths, resources: resources, inspector: oracle,
            clientFactory: { _ in oracle },
            portalFactory: {
                PortalWorkflow(client: $0, resources: resources, dataDirectory: paths.root)
            },
            diagnose: { _, _, _ in NetworkDiagnosis(evidence: ["reason": "synthetic-unreachable"])
            }, now: { 1000 },
            sleep: { _ in }, reassociate: { _ in }, discover: { _ in nil },
            forensics: { _, _, _, _ in nil })
    }
    func testNativeEngineAndProductionPortalCompleteStrictTwoStageGrant() async throws {
        let oracle = JourneyGrantOracle()
        let result = await engine(oracle).once(retry: false)
        XCTAssertEqual(result, 0)
        let evidence = await oracle.outcome()
        XCTAssertTrue(evidence.grant)
        XCTAssertEqual(evidence.paths, ["/register", "/activate"])
        XCTAssertEqual(evidence.probes, 3)
        XCTAssertTrue(evidence.errors.isEmpty)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertTrue(EvidenceStore(paths: paths).hasCapture("02:00:00:00:00:01", successful: true))
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 1)
    }
    func testServerRejectionThenExternalInternetCannotEarnAutomaticCredit() async throws {
        let oracle = JourneyGrantOracle()
        await oracle.rejectRegistration()
        let result = await engine(oracle).once(retry: false)
        XCTAssertEqual(result, 0)
        let evidence = await oracle.outcome()
        XCTAssertTrue(
            evidence.grant, "Independent internet became available, despite the rejected action")
        XCTAssertEqual(evidence.paths, ["/register"])
        XCTAssertNotEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 0)
    }
    func testIntegratedDiagnosticTraceKeepsOrderedFieldMeaningAndMasksValues() async throws {
        _ = await engine(JourneyGrantOracle()).once(retry: false)
        let log = try String(contentsOf: paths.log, encoding: .utf8)
        let events = try log.components(separatedBy: .newlines).compactMap {
            line -> [String: Any]? in
            guard let marker = line.range(of: "DIAGNOSTIC_STEP ") else { return nil }
            return try JSONSerialization.jsonObject(with: Data(line[marker.upperBound...].utf8))
                as? [String: Any]
        }
        let fields = events.flatMap { $0["fields"] as? [[String: Any]] ?? [] }
        XCTAssertTrue(
            fields.contains {
                $0["intent"] as? String == "email"
                    && ($0["name"] as? String)?.hasPrefix("field-") == true
            })
        XCTAssertTrue(
            fields.contains {
                $0["type"] as? String == "hidden" && $0["category"] as? String == "Server-provided"
            })
        XCTAssertTrue(fields.contains { $0["intent"] as? String == "first_name" })
        XCTAssertTrue(
            fields.allSatisfy { ["", "[masked]"].contains($0["maskedValue"] as? String ?? "") })
        let encoded = String(
            decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self)
        for secret in [
            "synthetic@example.test", "fresh-registration-token", "fresh-activation-token",
            "synthetic-password", "07700900123",
        ] { XCTAssertFalse(encoded.contains(secret)) }
        let email = try XCTUnwrap(fields.firstIndex { $0["intent"] as? String == "email" })
        let activation = try XCTUnwrap(
            fields.firstIndex { $0["intent"] as? String == "first_name" })
        XCTAssertLessThan(email, activation)
    }
}

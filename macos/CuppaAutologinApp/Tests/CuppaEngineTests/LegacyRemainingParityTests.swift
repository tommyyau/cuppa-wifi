import CuppaCore
import CuppaNetworking
import CuppaPortals
import Foundation
import XCTest

@testable import CuppaEngine

private actor JourneyOracle: HTTPClient, NetworkInspecting {
    let pages: [HTTPResponse]
    let snapshot: NetworkSnapshot
    let grant: Bool
    var index = 0
    var requests: [HTTPRequest] = []
    init(_ pages: [HTTPResponse], grant: Bool = true) {
        self.pages = pages
        self.grant = grant
        snapshot = NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest", wifiInterfaces: ["en0"])
    }
    func current() async -> NetworkSnapshot { snapshot }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.host == "captive.apple.com" {
            return index >= pages.count && grant
                ? HTTPResponse(url: request.url, status: 200, body: Data("Success".utf8))
                : HTTPResponse(
                    url: request.url, status: 302,
                    headers: ["Location": "https://portal.example/start"])
        }
        if request.url.host == "connectivitycheck.gstatic.com" {
            return HTTPResponse(
                url: request.url, status: index >= pages.count && grant ? 204 : 302,
                headers: ["Location": "https://portal.example/start"])
        }
        requests.append(request)
        guard index < pages.count else { throw URLError(.badServerResponse) }
        defer { index += 1 }
        return pages[index]
    }
    func observed() -> [HTTPRequest] { requests }
}
extension LegacyRemainingParityTests {
    func testHTTPServerErrorNeverEarnsAutomaticCreditFromUnrelatedOnlineAccess() async {
        let oracle = JourneyOracle(
            [page(ordinary), page(unavailable, path: "/grant", status: 503)], grant: true)
        _ = await engine(oracle).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "UNSUPPORTED")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"] ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
    }
}

final class LegacyRemainingParityTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    var paths: EnginePaths!
    let identity = PortalIdentity(values: [
        "FAKE_FIRST_NAME": "Sarah", "FAKE_LAST_NAME": "Chen",
        "FAKE_EMAIL": "sarah.chen@example.com", "FAKE_DOB": "1990-05-16", "FAKE_POSTCODE": "M1 1AE",
        "FAKE_PHONE": "07700900123", "SIGNUP_PASSWORD": "synthetic",
        "FAKE_ADDRESS_LINE_1": "10 Test Street", "FAKE_CITY": "Manchester",
        "FAKE_COUNTRY": "United Kingdom",
    ])
    var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macos/Resources")
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-final-parity-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
        try PrivateFile.write(
            Data(identity.values.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8),
            to: paths.identity)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func page(
        _ body: String, path: String = "/start", status: Int = 200, headers: [String: String] = [:]
    ) -> HTTPResponse {
        HTTPResponse(
            url: URL(string: "https://portal.example" + path)!, status: status, headers: headers,
            body: Data(body.utf8))
    }
    private func workflow(_ oracle: JourneyOracle) -> PortalWorkflow {
        PortalWorkflow(client: oracle, resources: resources, dataDirectory: root)
    }
    private func engine(_ oracle: JourneyOracle) -> CuppaEngine {
        CuppaEngine(
            paths: paths, resources: resources, inspector: oracle, clientFactory: { _ in oracle },
            portalFactory: {
                PortalWorkflow(client: $0, resources: self.resources, dataDirectory: self.root)
            }, diagnose: { _, _, _ in NetworkDiagnosis(evidence: [:]) }, now: { 1000 },
            sleep: { _ in }, reassociate: { _ in }, discover: { _ in nil },
            forensics: { _, _, _, _ in nil })
    }
    func fields(_ request: HTTPRequest) -> [String: String] {
        let value =
            request.method == "GET"
            ? request.url.query ?? "" : String(decoding: request.body ?? Data(), as: UTF8.self)
        return (URLComponents(string: "https://x.test/?" + value)?.queryItems ?? []).reduce(
            into: [:]) { $0[$1.name] = $1.value ?? "" }
    }
    let ordinary =
        "<form method='post' action='/grant'><input name='email' type='email' required><button>Connect</button></form>"
    let unavailable =
        "<title>Service unavailable</title><h1>Service unavailable</h1><form action='/search'><input name='q'></form>"
    func testColdRegistrationPreservesFullPersonaAndConsent() async throws {
        let html =
            "<form method='post' action='/grant'><input name='firstname'><input name='lastname'><input name='email' type='email'><input name='postcode'><input name='phone'><label for='terms'>Accept terms and conditions</label><input id='terms' name='terms' type='checkbox' value='yes'><label for='offers'>Marketing offers</label><input id='offers' name='marketing' type='checkbox' value='yes'><button name='submit' value='Connect'>Connect</button></form>"
        let oracle = JourneyOracle([page(html), page("Connected", path: "/grant")])
        _ = await engine(oracle).once(retry: false)
        let sent = await oracle.observed()
        XCTAssertEqual(sent.count, 2)
        let data = fields(sent[1])
        for (key, value) in [
            "firstname": "Sarah", "lastname": "Chen", "email": "sarah.chen@example.com",
            "postcode": "M1 1AE", "phone": "07700900123", "terms": "yes",
        ] { XCTAssertEqual(data[key], value, key) }
        XCTAssertNil(data["marketing"])
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"])
    }
    func testColdStrictJourneyUsesFreshTokensLabelledFieldsAndTerms() async throws {
        let labels = [
            "First name", "Last name", "Email address", "Date of birth (DD/MM/YYYY)",
            "Address line 1", "Town or city", "Postcode",
        ]
        let inputs = labels.enumerated().map {
            "<label for='f\($0.offset+1)'>\($0.element)</label><input id='f\($0.offset+1)' name='field_\($0.offset+1)' required>"
        }.joined()
        let html =
            "<form method='post' action='/profile'><input type='hidden' name='csrf' value='token-123'>"
            + inputs
            + "<label for='f8'>Country</label><select id='f8' name='field_8' required><option value=''>Choose</option><option value='GB'>United Kingdom</option></select><button>Continue</button></form>"
        let terms =
            "<form method='post' action='/accept'><input type='hidden' name='grant_token' value='grant-456'><label for='terms'>Accept terms and privacy policy</label><input id='terms' name='terms' type='checkbox' value='accepted' required><button>Connect</button></form>"
        let oracle = JourneyOracle([
            page(html, headers: ["Set-Cookie": "portal_session=session-abc; Path=/"]),
            page("<meta http-equiv='refresh' content='0;url=/terms'>", path: "/profile"),
            page(terms, path: "/terms"), page("Connected", path: "/accept"),
        ])
        _ = await engine(oracle).once(retry: false)
        let sent = await oracle.observed()
        XCTAssertEqual(sent.count, 4)
        guard sent.count == 4 else { return }
        let profile = fields(sent[1])
        for (index, value) in [
            "Sarah", "Chen", "sarah.chen@example.com", "16/05/1990", "10 Test Street", "Manchester",
            "M1 1AE", "GB",
        ].enumerated() { XCTAssertEqual(profile["field_\(index+1)"], value) }
        XCTAssertEqual(profile["csrf"], "token-123")
        XCTAssertEqual(sent[2].url.path, "/terms")
        XCTAssertEqual(fields(sent[3])["grant_token"], "grant-456")
        XCTAssertEqual(fields(sent[3])["terms"], "accepted")
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"])
    }
    func testSearchSidebarDoesNotHideRealForm() async {
        let oracle = JourneyOracle([
            page("<form action='/search'><input name='q'></form>" + ordinary),
            page("Connected", path: "/grant"),
        ])
        let result = await workflow(oracle).login(
            url: URL(string: "https://portal.example/start")!, identity: identity,
            network: await oracle.current())
        let sent = await oracle.observed()
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.url.path, "/grant")
        XCTAssertNil(sent.last.map(fields)?["q"])
    }
    func testUnavailableResponseAfterPostStopsFurtherActions() async {
        await assertUnavailable([page(ordinary), page(unavailable, path: "/grant")], count: 2)
    }
    private func assertUnavailable(_ pages: [HTTPResponse], count: Int) async {
        let oracle = JourneyOracle(pages, grant: false)
        let result = await workflow(oracle).login(
            url: URL(string: "https://portal.example/start")!, identity: identity,
            network: await oracle.current())
        XCTAssertEqual(result.reason, "portal_page_unavailable")
        XCTAssertEqual(result.outcome, .unsupported)
        let sent = await oracle.observed()
        XCTAssertEqual(sent.count, count)
        XCTAssertFalse(sent.contains { $0.url.path == "/search" })
    }
    func testUnavailableCorrectionResponseStopsFurtherActions() async {
        let form = "<form method='post' action='/grant'><input name='postcode' required></form>"
        let rejected =
            "<p class='error'>Please enter a valid postcode</p>"
            + form.replacingOccurrences(
                of: "name='postcode'", with: "name='postcode' aria-invalid='true'")
        await assertUnavailable(
            [
                page(form), page(rejected, path: "/grant", status: 422),
                page("<title>Service unavailable</title>" + rejected, path: "/grant", status: 503),
            ], count: 3)
    }
    func testOrdinaryGETFormRemainsStatic() async {
        let oracle = JourneyOracle([
            page(
                "<form method='get' action='/grant'><input name='email' type='email'><button>Connect</button></form>"
            ), page("Connected", path: "/grant"),
        ])
        let result = await workflow(oracle).login(
            url: URL(string: "https://portal.example/start")!, identity: identity,
            network: await oracle.current())
        let sent = await oracle.observed()
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent.last?.method, "GET")
        XCTAssertEqual(sent.last.map(fields)?["email"], identity.email)
    }
    func testSoftErrorGrantNeedsIndependentConnectivity() async {
        for online in [false, true] {
            PrivateFile.remove(paths.state)
            PrivateFile.remove(paths.unsupported)
            let oracle = JourneyOracle(
                [
                    page(ordinary),
                    page(
                        "<title>Page Not Found</title><form><input type='search' name='s'></form>",
                        path: "/grant"),
                ], grant: online)
            _ = await engine(oracle).once(retry: false)
            XCTAssertEqual(EngineState.load(paths).result, online ? "ONLINE" : "UNSUPPORTED")
            XCTAssertEqual(
                EvidenceStore(paths: paths).summary()["automatic_verified"] ?? 0, online ? 1 : 0)
        }
    }
    func testRedirectChainOnlineRecoveryHasNoAutomaticCreditOrHandoff() async {
        let oracle = JourneyOracle([
            page("<meta http-equiv='refresh' content='0;url=/bridge'>"),
            page("<script>window.location.href='/landing'</script>", path: "/bridge"),
            page("<h1>Welcome</h1>", path: "/landing"),
        ])
        _ = await engine(oracle).once(retry: false)
        let sent = await oracle.observed()
        XCTAssertEqual(sent.map(\.url.path), ["/start", "/bridge", "/landing"])
        XCTAssertTrue(sent.allSatisfy { $0.method == "GET" })
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"] ?? 0, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testMixedSpaceAndPercentEncodedHandoffURLPreserved() throws {
        let raw = "https://portal.example/join page?next=https%3A%2F%2Fexample.com"
        try PrivateFile.writeJSON(
            [
                "portal_url": raw, "reason": "requires_browser", "written_at": 1000,
                "deadline": 1090, "venue_fingerprint": "venue", "network_interface": "en0",
                "network_gateway_ip": "192.0.2.1",
            ], to: paths.handoff)
        let record = BrowserHandoffStore(paths: paths).active(fingerprint: "venue", now: 1001)
        XCTAssertTrue(record)
        XCTAssertEqual(
            PortalRequestURL.url(raw)?.absoluteString,
            "https://portal.example/join%20page?next=https%3A%2F%2Fexample.com")
    }
    func testCaptureDiagnosticReasonManifestDetailAndPermissions() throws {
        let phone = PortalStepField(
            name: "phone", type: "tel", intent: "phone", source: "persona", category: "Generated")
        let email = PortalStepField(
            name: "email", type: "email", intent: "email", source: "persona", category: "Generated")
        let url = URL(string: "https://portal.example/login?token=private")!
        let attempt = PortalAttempt(
            outcome: .failed, reason: "form_rejected", portalURL: url,
            hops: [
                PortalHop(
                    request: HTTPRequest(url: url, method: "POST"),
                    response: page("private body", path: "/login", status: 422))
            ],
            steps: [
                PortalStep(phase: "validation", title: "Rejected", fields: [phone, email]),
                PortalStep(phase: "validation", title: "Still rejected", fields: [email]),
            ])
        let directory = try XCTUnwrap(
            EvidenceStore(paths: paths, resources: resources).capture(
                attempt, fingerprint: "venue", successful: false, now: 1000))
        let diagnostic = try XCTUnwrap(
            PrivateFile.object(at: directory.appendingPathComponent("diagnostic.json")))
        XCTAssertEqual(diagnostic["failure_reason"] as? String, "form_rejected")
        let fields = try XCTUnwrap(
            (diagnostic["failure_detail"] as? [String: Any])?["fieldsStillFailing"]
                as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields[0]["intent"] as? String, "email")
        XCTAssertTrue((fields[0]["name"] as? String ?? "").hasPrefix("field-"))
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            as! [[String: Any]]
        XCTAssertEqual(manifest.first?["method"] as? String, "POST")
        XCTAssertEqual(manifest.first?["status"] as? Int, 422)
        for name in [
            "manifest.json", "diagnostic.json", "safe_report.json", "01_body.html",
            "01_headers.json",
        ] {
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path)[.posixPermissions]
                    as? NSNumber)?.intValue, 0o600)
        }
    }
    func testCaptureJSONSchemaAndValidationNamesExcludeMessages() throws {
        let body =
            "{\"stdFields\":[{\"name\":\"email\",\"type\":\"email\",\"required\":true}],\"validationFieldErrors\":{\"email\":\"SECRET_MESSAGE user@example.test\"},\"success\":false}"
        let url = URL(string: "https://portal.example/start")!
        let attempt = PortalAttempt(
            outcome: .failed, reason: "form_rejected", portalURL: url,
            hops: [
                PortalHop(
                    request: HTTPRequest(url: url),
                    response: page(body, headers: ["Content-Type": "application/json"]))
            ])
        let directory = try XCTUnwrap(
            EvidenceStore(paths: paths, resources: resources).capture(
                attempt, fingerprint: "venue", successful: false, now: 1000))
        let report = try XCTUnwrap(
            PrivateFile.object(at: directory.appendingPathComponent("safe_report.json")))
        let hop = try XCTUnwrap((report["hops"] as? [[String: Any]])?.first)
        XCTAssertTrue((hop["response_keys"] as? [String] ?? []).contains("success"))
        XCTAssertEqual(hop["validation_fields"] as? [String], ["email"])
        XCTAssertTrue(
            (hop["declared_fields"] as? [[String: Any]] ?? []).contains {
                $0["name"] as? String == "email"
            })
        let text = String(
            decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
        XCTAssertFalse(text.contains("SECRET_MESSAGE"))
        XCTAssertFalse(text.contains("user@example.test"))
    }
    func triageFixture() throws {
        let capture = paths.captures.appendingPathComponent("venue_one/20000101T120000Z")
        try PrivateFile.writeJSON(
            ["failure_reason": "form_rejected"],
            to: capture.appendingPathComponent("diagnostic.json"))
        try PrivateFile.writeJSON(
            [["method": "POST", "url": "https://portal.example/register", "status": 422]],
            to: capture.appendingPathComponent("manifest.json"))
        try PrivateFile.writeJSON(
            ["gateway_ip": "192.0.2.1", "notes": ["Synthetic forensic note"]],
            to: paths.forensics.appendingPathComponent("venue_one/20000101T120001Z/summary.json"))
        try PrivateFile.write(
            Data("venue_one scoped log\nunrelated private line\n".utf8), to: paths.log)
    }
    func testTriagePrivateReportIncludesReasonHopsForensicsAndScopedLogs() throws {
        try triageFixture()
        let text = TriageReport(paths: paths).render(selector: "venue_one")
        for token in [
            "form_rejected", "POST", "422", "https://portal.example/register", "Forensics:",
            "192.0.2.1", "Synthetic forensic note", "scoped log",
        ] { XCTAssertTrue(text.contains(token), token) }
        XCTAssertFalse(text.contains("unrelated private line"))
    }
    func testTriageSubstringAndNoMatchListKnownVenues() throws {
        try triageFixture()
        XCTAssertTrue(TriageReport(paths: paths).render(selector: "ONE").contains("form_rejected"))
        let missing = TriageReport(paths: paths).render(selector: "absent")
        XCTAssertTrue(missing.contains("No venue matched"))
        XCTAssertTrue(missing.contains("venue_one"))
    }

}

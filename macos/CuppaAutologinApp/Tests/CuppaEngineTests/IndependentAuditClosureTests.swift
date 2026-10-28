import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

final class IndependentAuditClosureTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var paths: EnginePaths!
    private var clock: EngineClock!
    private var network: NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest", dhcpDomain: "guest.example", wifiInterfaces: ["en0"])
    }
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macos/Resources")
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "independent-closure-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
        clock = EngineClock()
        try PrivateFile.write(
            Data(
                "FAKE_FIRST_NAME=Synthetic\nFAKE_LAST_NAME=Guest\nFAKE_EMAIL=synthetic@example.test\nFAKE_DOB=1990-01-01\nFAKE_POSTCODE=SW1A 1AA\nFAKE_PHONE=07700900123\nSIGNUP_PASSWORD=synthetic\n"
                    .utf8), to: paths.identity)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func engine(_ fixture: EngineFixture) -> CuppaEngine {
        let clock = clock!
        return CuppaEngine(
            paths: paths, resources: resources, inspector: fixture, clientFactory: { _ in fixture },
            portalFactory: { _ in fixture },
            diagnose: { _, _, _ in NetworkDiagnosis(evidence: ["reason": "upstream_unavailable"]) },
            now: { clock.now() }, sleep: { clock.sleep($0) }, reassociate: { clock.recovery($0) },
            discover: { _ in nil }, forensics: { _, _, _, _ in nil })
    }
    private func pending() throws -> URL {
        try EngineState(fields: [
            "gateway_mac": network.gatewayMAC!, "ssid": network.ssid!,
            "dhcp_domain": network.dhcpDomain!, "portal_domain": "portal.example",
            "last_result": "CAPTIVE", "consecutive_failures": 3,
        ]).save(paths)
        let signature = String(repeating: "a", count: 64)
        try BrowserHandoffStore(paths: paths).write(
            attempt: PortalAttempt(
                outcome: .browser, reason: "requires_browser",
                portalURL: URL(string: "https://portal.example/login")!, signature: signature),
            network: network, fingerprint: network.gatewayMAC, cookies: [], capturedPath: nil,
            firstVisit: true, now: clock.now())
        let report = paths.journeys.appendingPathComponent("browser.json")
        try PrivateFile.writeJSON(
            [
                "format": 1, "source": "automatic", "host": "portal.example", "provider": "generic",
                "signature": signature, "outcome": "pending_verification",
                "journey": ["actions": 1, "trace": []],
            ], to: report)
        return report
    }
    func testFirstVerifiedStaticSuccessCreatesSuccessCaptureArtifact() async throws {
        let fixture = EngineFixture(network: network)
        _ = await engine(fixture).once(retry: false)
        let parent = paths.captures.appendingPathComponent(
            EvidenceStore.safeKey(network.gatewayMAC!))
        let captures = try FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil)
        XCTAssertEqual(captures.count, 1)
        let directory = try XCTUnwrap(captures.first)
        let diagnostic = try XCTUnwrap(
            PrivateFile.object(at: directory.appendingPathComponent("diagnostic.json")))
        XCTAssertEqual(diagnostic["outcome"] as? String, "success")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("safe_report.json").path))
        XCTAssertTrue(EvidenceStore(paths: paths).hasCapture(network.gatewayMAC!, successful: true))
    }
    func testVisitCountsAndSerializedJourneysHidePrivateVenueFingerprint() throws {
        let store = EvidenceStore(paths: paths)
        let fingerprint = "private-venue-id"
        XCTAssertFalse(store.seenVenue(fingerprint))
        store.staticOutcome(
            host: "portal.example", provider: "generic", fingerprint: fingerprint,
            outcome: "verified", firstVisit: true, now: 100)
        XCTAssertTrue(store.seenVenue(fingerprint))
        XCTAssertFalse(store.seenVenue("other-venue"))
        store.staticOutcome(
            host: "portal.example", provider: "generic", fingerprint: fingerprint,
            outcome: "verified", firstVisit: false, now: 200)
        XCTAssertEqual(store.summary()["first_visit_verified"], 1)
        XCTAssertEqual(store.summary()["returning_verified"], 1)
        for file in try FileManager.default.contentsOfDirectory(
            at: paths.journeys, includingPropertiesForKeys: nil) where file.pathExtension == "json"
        {
            XCTAssertFalse(
                try String(contentsOf: file, encoding: .utf8).contains(fingerprint),
                file.lastPathComponent)
        }
    }
    func testStructuralReportRetainsExactRejectedFieldWithoutValue() throws {
        let report = paths.journeys.appendingPathComponent("rejected.json")
        try PrivateFile.writeJSON(
            [
                "format": 1, "host": "portal.example",
                "fieldsStillFailing": [
                    ["intent": "email", "type": "email", "value": "private@example.test"]
                ],
                "journey": [
                    "actions": 1,
                    "trace": [
                        [
                            "signature": "abcdef12", "action": "1234abcd", "elapsed_ms": 1234,
                            "outcome": "unchanged", "stage": "registration", "fields": [],
                        ]
                    ],
                ],
            ], to: report)
        let value = try XCTUnwrap(EvidenceStore(paths: paths).report(at: report))
        let fields = try XCTUnwrap(value["fieldsStillFailing"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(Set(fields[0].keys), Set(["intent", "type"]))
        XCTAssertEqual(fields[0]["intent"] as? String, "email")
        XCTAssertEqual(fields[0]["type"] as? String, "email")
        XCTAssertFalse(
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
                .contains("private@example.test"))
        let row = ((value["journey"] as? [String: Any])?["trace"] as? [[String: Any]])?.first
        XCTAssertEqual(row?["elapsed_ms"] as? Int, 1234)
        XCTAssertEqual(row?["action"] as? String, "1234abcd")
        XCTAssertEqual(row?["outcome"] as? String, "unchanged")
    }
    func testReasoningCountersRejectNegativeStringAndBooleanValues() throws {
        for (index, requests, decisions, expectedRequests, expectedDecisions) in [
            (0, 3 as Any, 2 as Any, 3, 2), (1, 999 as Any, -1 as Any, 12, 0),
            (2, true as Any, "bad" as Any, 0, 0), (3, "bad" as Any, -1 as Any, 0, 0),
        ] {
            let path = paths.journeys.appendingPathComponent("reasoning-\(index).json")
            try PrivateFile.writeJSON(
                [
                    "format": 1, "host": "portal.example", "local_reasoning_requests": requests,
                    "local_reasoning_decisions": decisions, "model_prompt": "private@example.test",
                    "model_answer": "private",
                    "journey": [
                        "trace": [
                            [
                                "signature": "abcdef12",
                                "fields": [
                                    [
                                        "intent": "terms", "type": "checkbox", "required": true,
                                        "value": "private",
                                    ]
                                ],
                            ]
                        ]
                    ],
                ], to: path)
            let report = try XCTUnwrap(EvidenceStore(paths: paths).report(at: path))
            XCTAssertEqual(report["local_reasoning_requests"] as? Int, expectedRequests)
            XCTAssertEqual(report["local_reasoning_decisions"] as? Int, expectedDecisions)
            XCTAssertFalse(
                String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
                    .contains("private"))
            let fields =
                (((report["journey"] as? [String: Any])?["trace"] as? [[String: Any]])?.first?[
                    "fields"] as? [[String: Any]])
            XCTAssertEqual(fields?.first?["intent"] as? String, "terms")
        }
    }
    func testSafeCaptureExactFieldShapeProviderHintURLAndPrivacyFlags() throws {
        let url = URL(
            string:
                "https://wifi.wireless-social.com/login?client_mac=aa:bb:cc:dd:ee:ff&token=token-abc-123"
        )!
        let html =
            "<html><title>Guest Wi-Fi</title><script>window.journeyData = {};</script><form method='post' action='/journey/auth/user/form?token=token-abc-123'><input type='email' name='email' required value='person@private.example'><input type='hidden' name='csrf' value='token-abc-123'></form></html>"
        let response = HTTPResponse(
            url: url, status: 422,
            headers: [
                "Set-Cookie": "session=token-abc-123", "Content-Type": "text/html; charset=utf-8",
            ], body: Data(html.utf8))
        let capture = try XCTUnwrap(
            EvidenceStore(paths: paths, resources: resources).capture(
                PortalAttempt(
                    outcome: .failed, reason: "privacy_email_required", portalURL: url,
                    hops: [
                        PortalHop(
                            request: HTTPRequest(url: url, method: "POST"), response: response)
                    ]), fingerprint: "venue", successful: false, now: 100))
        let report = try XCTUnwrap(
            PrivateFile.object(at: capture.appendingPathComponent("safe_report.json")))
        let hop = try XCTUnwrap((report["hops"] as? [[String: Any]])?.first)
        XCTAssertEqual(report["format"] as? Int, 2)
        XCTAssertEqual(hop["url"] as? String, "https://wifi.wireless-social.com/login")
        XCTAssertTrue((hop["provider_hints"] as? [String] ?? []).contains("wireless_social"))
        let field = try XCTUnwrap(
            ((hop["forms"] as? [[String: Any]])?.first?["fields"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(field.keys),
            Set([
                "autocomplete", "has_pattern", "inputmode", "intent", "maxlength", "name",
                "required", "type",
            ]))
        XCTAssertTrue(field["autocomplete"] is NSNull)
        XCTAssertTrue(field["inputmode"] is NSNull)
        XCTAssertTrue(field["maxlength"] is NSNull)
        XCTAssertEqual(field["has_pattern"] as? Bool, false)
        XCTAssertEqual(field["intent"] as? String, "email")
        XCTAssertEqual(field["name"] as? String, "email")
        XCTAssertEqual(field["required"] as? Bool, true)
        XCTAssertEqual(field["type"] as? String, "email")
        let text = String(
            decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
        for secret in [
            "person@private.example", "token-abc-123", "aa:bb:cc:dd:ee:ff", "Set-Cookie",
        ] { XCTAssertFalse(text.contains(secret)) }
    }
    func testFailedBrowserConsensusUsesThreeCyclesAndNeverLearnsOrCredits() async throws {
        let report = try pending()
        let fixture = EngineFixture(network: network, initial: .appleOnly)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, report: report)
        XCTAssertEqual(result, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        let requests = await fixture.requests
        XCTAssertEqual(requests.filter { $0.url.host == "captive.apple.com" }.count, 3)
        XCTAssertEqual(requests.filter { $0.url.host == "connectivitycheck.gstatic.com" }.count, 3)
        XCTAssertEqual(clock.counts().sleeps, [0.5, 1.0])
        XCTAssertEqual(PrivateFile.object(at: report)?["outcome"] as? String, "not_verified")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testStaleFingerprintAndChangedGatewayRetainCaptiveStateAndHandoff() async throws {
        _ = try pending()
        let handoff = try Data(contentsOf: paths.handoff)
        let fixture = EngineFixture(network: network, initial: .online)
        let stale = await engine(fixture).completeBrowser(fingerprint: "other-venue")
        XCTAssertEqual(stale, 4)
        let before = await fixture.stats()
        XCTAssertEqual(before.requests, 0)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertEqual(try Data(contentsOf: paths.handoff), handoff)
        await fixture.changeDuringProbe()
        let changed = await engine(fixture).completeBrowser(fingerprint: network.gatewayMAC)
        XCTAssertEqual(changed, 4)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(try Data(contentsOf: paths.handoff), handoff)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
    }
}
extension IndependentAuditClosureTests {
    func testCaptureProviderPhoneSchemaAndRejectedFieldExactShapeWithoutMessages() throws {
        let secret = "This value is not valid phone number."
        let url = URL(string: "https://wifi.wireless-social.com/journey/register/user")!
        let body = try JSONSerialization.data(withJSONObject: [
            "success": false,
            "stdFields": [
                [
                    "name": "mobilenumber", "type": "phone", "label": "Mobile telephone",
                    "requirement": "required",
                ]
            ], "validationFieldErrors": [["fieldName": "mobilenumber", "errors": [secret]]],
        ])
        let response = HTTPResponse(
            url: url, status: 200, headers: ["Content-Type": "application/json"], body: body)
        let capture = try XCTUnwrap(
            EvidenceStore(paths: paths, resources: resources).capture(
                PortalAttempt(
                    outcome: .failed, reason: "persona_phone_rejected", portalURL: url,
                    hops: [
                        PortalHop(
                            request: HTTPRequest(url: url, method: "POST"), response: response)
                    ]), fingerprint: "venue", successful: false, now: 100))
        let report = try XCTUnwrap(
            PrivateFile.object(at: capture.appendingPathComponent("safe_report.json")))
        let hop = try XCTUnwrap((report["hops"] as? [[String: Any]])?.first)
        let fields = try XCTUnwrap(hop["declared_fields"] as? [[String: Any]])
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(
            Set(fields[0].keys), Set(["collection", "intent", "name", "required", "type"]))
        XCTAssertEqual(fields[0]["collection"] as? String, "stdFields")
        XCTAssertEqual(fields[0]["intent"] as? String, "phone")
        XCTAssertEqual(fields[0]["name"] as? String, "mobilenumber")
        XCTAssertEqual(fields[0]["required"] as? Bool, true)
        XCTAssertEqual(fields[0]["type"] as? String, "phone")
        XCTAssertEqual(hop["validation_fields"] as? [String], ["mobilenumber"])
        XCTAssertFalse(
            String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
                .contains(secret))
    }
}

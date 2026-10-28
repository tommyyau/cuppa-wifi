import CuppaCore
import Darwin
import Foundation
import XCTest

@testable import CuppaEngine

final class PersistenceBoundaryTests: XCTestCase {
    private var root: URL!
    private var paths: EnginePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("logs/engine.log"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber)
            .intValue
    }
    private var network: NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest", dhcpDomain: "guest.example", wifiInterfaces: ["en0"])
    }
    private func report(_ values: [String: Any] = [:], name: String = "report.json") throws -> URL {
        var base: [String: Any] = [
            "format": 1, "host": "PORTAL.EXAMPLE", "provider": "generic",
            "outcome": "pending_verification", "journey": ["actions": 1, "trace": []],
        ]
        for (key, value) in values { base[key] = value }
        let target = paths.journeys.appendingPathComponent(name)
        try PrivateFile.writeJSON(base, to: target)
        return target
    }

    func testReadingMissingStateDoesNotCreateDataRoot() {
        XCTAssertEqual(EngineState.load(paths).result, "UNKNOWN")
        XCTAssertEqual(EngineState.load(paths).failures, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
    func testEmptyEnvironmentOverrideFallsBackToSharedHomeDirectory() {
        let original = getenv("WIFI_AUTOLOGIN_DATA_DIR").map { String(cString: $0) }
        defer {
            if let original {
                setenv("WIFI_AUTOLOGIN_DATA_DIR", original, 1)
            } else {
                unsetenv("WIFI_AUTOLOGIN_DATA_DIR")
            }
        }
        setenv("WIFI_AUTOLOGIN_DATA_DIR", "", 1)
        let resolved = EnginePaths(log: paths.log)
        XCTAssertEqual(
            resolved.root,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".local/state/wifi-autologin"))
    }
    func testMalformedAndOversizedObjectsFailClosed() throws {
        try PrivateFile.write(Data("[]".utf8), to: paths.state)
        XCTAssertEqual(EngineState.load(paths).result, "UNKNOWN")
        try PrivateFile.write(Data("{broken".utf8), to: paths.state)
        XCTAssertEqual(EngineState.load(paths).result, "UNKNOWN")
        try PrivateFile.writeJSON(["secret": String(repeating: "x", count: 300)], to: paths.state)
        XCTAssertNil(PrivateFile.object(at: paths.state, maximumBytes: 100))
    }
    func testPrivateAtomicReplacementAndNoTemporaryLeftovers() throws {
        try PrivateFile.writeJSON(["value": "before"], to: paths.state)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: paths.state.path)
        try PrivateFile.writeJSON(["value": "after"], to: paths.state)
        XCTAssertEqual(PrivateFile.object(at: paths.state)?["value"] as? String, "after")
        XCTAssertEqual(try mode(paths.state), 0o600)
        XCTAssertEqual(try mode(root), 0o700)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path), ["state.json"])
    }
    func testUnknownStateFieldsSurviveRoundTrip() throws {
        let state = EngineState(fields: ["future_feature": ["format": 2], "last_result": "CAPTIVE"])
        try state.save(paths)
        XCTAssertEqual(
            EngineState.load(paths).fields["future_feature"] as? [String: Int], ["format": 2])
    }
    func testNetworkSwitchClearsOldVenueAndLoginEvidence() {
        var state = EngineState(fields: [
            "gateway_mac": "02:00:00:00:00:ff", "ssid": "Old", "last_result": "ONLINE",
            "venue": "Old Venue", "last_login_ts": 10.0, "last_connection_ts": 9.0,
            "consecutive_failures": 4, "network_diagnostic": ["reason": "old"],
            "last_notified_event": "old",
        ])
        XCTAssertTrue(state.begin(network: network, now: 100))
        XCTAssertEqual(state.result, "UNKNOWN")
        XCTAssertEqual(state.failures, 0)
        for key in [
            "venue", "last_login_ts", "last_connection_ts", "network_diagnostic",
            "last_notified_event",
        ] { XCTAssertNil(state.fields[key], key) }
    }
    func testRedactedSSIDDoesNotEraseKnownSession() {
        var state = EngineState(fields: [
            "gateway_mac": network.gatewayMAC!, "ssid": network.ssid!, "last_login_ts": 10.0,
            "venue": "Known",
        ])
        var redacted = network
        redacted.ssid = nil
        XCTAssertFalse(state.begin(network: redacted, now: 100))
        XCTAssertEqual(state.fields["ssid"] as? String, network.ssid)
        XCTAssertEqual(state.fields["venue"] as? String, "Known")
    }
    func testLateGatewayDiscoveryAttachesToVerifiedLogin() {
        var state = EngineState(fields: ["last_login_ts": 10.0, "ssid": network.ssid!])
        XCTAssertFalse(state.begin(network: network, now: 100))
        XCTAssertEqual(state.fields["last_login_gateway_mac"] as? String, network.gatewayMAC)
        XCTAssertEqual(state.fields["last_login_ts"] as? Double, 10)
    }
    func testManualOnlineDoesNotEarnAutomaticLoginTimestamp() {
        var state = EngineState(fields: ["last_result": "UNSUPPORTED", "consecutive_failures": 4])
        state.markOnline(network: network, now: 100, automatedLogin: false)
        XCTAssertEqual(state.result, "ONLINE")
        XCTAssertEqual(state.failures, 0)
        XCTAssertNil(state.fields["last_login_ts"])
        XCTAssertEqual(state.fields["last_connection_ts"] as? Double, 100)
    }
    func testHealthyPollKeepsOriginalConnectionTime() {
        var state = EngineState(fields: [
            "last_result": "ONLINE", "last_connection_ts": 10.0, "last_login_ts": 11.0,
        ])
        state.markOnline(network: network, now: 100, automatedLogin: false)
        XCTAssertEqual(state.fields["last_connection_ts"] as? Double, 10)
        XCTAssertEqual(state.fields["last_login_ts"] as? Double, 11)
    }
    func testSharedGatewayCannotBeFingerprintFallback() {
        for mac in [
            "00:00:0c:07:ac:01", "00:00:0c:9f:f0:01", "00:07:b4:00:00:01", "00:00:5e:00:01:01",
        ] {
            XCTAssertTrue(NetworkIdentity.isSharedMAC(mac))
            XCTAssertNil(NetworkIdentity.fingerprint(NetworkSnapshot(gatewayMAC: mac)))
            XCTAssertEqual(
                NetworkIdentity.fingerprint(
                    NetworkSnapshot(gatewayMAC: mac, ssid: "Venue"), portalDomain: "portal.example"),
                "portal.example")
        }
        XCTAssertEqual(
            NetworkIdentity.fingerprint(network, portalDomain: "shared-provider.example"),
            network.gatewayMAC)
    }
    func testDHCPChangeSeparatesSharedGatewayVenues() {
        let old = NetworkSnapshot(gatewayMAC: "00:00:0c:9f:f0:01", dhcpDomain: "old.example")
        let new = NetworkSnapshot(gatewayMAC: old.gatewayMAC, dhcpDomain: "new.example")
        XCTAssertTrue(NetworkIdentity.changed(from: old, to: new))
    }
    func testLockRejectsConcurrentOwnerAndReleases() throws {
        var first = EngineLock.acquire(paths.lock)
        XCTAssertNotNil(first)
        XCTAssertNil(EngineLock.acquire(paths.lock))
        XCTAssertEqual(try mode(paths.lock), 0o600)
        first = nil
        XCTAssertNotNil(EngineLock.acquire(paths.lock))
    }
    func testLockCannotFollowSymbolicLink() throws {
        try PrivateFile.directory(root)
        let outside = root.appendingPathComponent("outside")
        try PrivateFile.write(Data("untouched".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: paths.lock, withDestinationURL: outside)
        XCTAssertNil(EngineLock.acquire(paths.lock))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "untouched")
    }
    func testHandoffCarriesSessionAndClampsBudgets() throws {
        let attempt = PortalAttempt(
            outcome: .browser, reason: "requires_browser",
            portalURL: URL(string: "https://portal.example/login")!, actions: 20,
            pendingSubmission: true, corrections: ["phone": ["international"]],
            signature: String(repeating: "a", count: 64))
        let cookies = (0..<110).map {
            PortalCookie(name: "cookie\($0)", value: "synthetic", domain: "portal.example")
        }
        let store = BrowserHandoffStore(paths: paths)
        try store.write(
            attempt: attempt, network: network, fingerprint: "venue", cookies: cookies,
            capturedPath: nil, firstVisit: true, now: 100)
        let value = try XCTUnwrap(PrivateFile.object(at: paths.handoff))
        XCTAssertEqual((value["cookies"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual(value["previous_actions"] as? Int, 8)
        XCTAssertEqual(value["deadline"] as? Double, 190)
        XCTAssertEqual(value["pending_submission"] as? Bool, true)
        XCTAssertEqual(value["network_interface"] as? String, "en0")
        XCTAssertEqual(value["network_gateway_ip"] as? String, network.gatewayIP)
        XCTAssertEqual(try mode(paths.handoff), 0o600)
        XCTAssertTrue(store.active(fingerprint: "venue", now: 101))
    }
    func testHandoffRejectsChangedVenueFutureTimeAndDeadline() throws {
        let store = BrowserHandoffStore(paths: paths)
        try store.write(
            attempt: PortalAttempt(
                outcome: .browser, reason: "requires_browser",
                portalURL: URL(string: "https://portal.example/")!), network: network,
            fingerprint: "venue", cookies: [], capturedPath: nil, firstVisit: true, now: 100)
        XCTAssertFalse(store.active(fingerprint: "another", now: 101))
        XCTAssertFalse(store.active(fingerprint: "venue", now: 99))
        XCTAssertFalse(store.active(fingerprint: "venue", now: 190))
    }
    func testBooleanHandoffTimestampCannotAuthorizeWork() throws {
        let store = BrowserHandoffStore(paths: paths)
        try PrivateFile.writeJSON(
            [
                "reason": "requires_browser", "portal_url": "https://portal.example/",
                "venue_fingerprint": "venue", "written_at": true, "deadline": 90,
            ], to: paths.handoff)
        XCTAssertFalse(store.active(fingerprint: "venue", now: 2))
        try PrivateFile.writeJSON(
            [
                "reason": "requires_browser", "portal_url": "https://portal.example/",
                "venue_fingerprint": "venue", "written_at": 0, "deadline": true,
            ], to: paths.handoff)
        XCTAssertFalse(store.active(fingerprint: "venue", now: 0.5))
    }
    func testBooleanUnsupportedTimestampDoesNotCreateVenueVerdict() throws {
        try PrivateFile.writeJSON(
            ["reason": "captcha_required", "venue_fingerprint": "venue", "written_at": true],
            to: paths.unsupported)
        XCTAssertNil(BrowserHandoffStore(paths: paths).unsupported(fingerprint: "venue", now: 2))
    }
    func testManualUnsupportedHandoffNeverStartsAutomation() throws {
        let store = BrowserHandoffStore(paths: paths)
        try store.write(
            attempt: PortalAttempt(
                outcome: .unsupported, reason: "requires_otp",
                portalURL: URL(string: "https://portal.example/")!), network: network,
            fingerprint: "venue", cookies: [], capturedPath: nil, firstVisit: true, now: 100)
        XCTAssertFalse(store.active(fingerprint: "venue", now: 101))
        XCTAssertEqual(
            PrivateFile.object(at: paths.handoff)?["unsupported_reason"] as? String, "requires_otp")
    }
    func testUnsupportedOutcomeIsScopedAndExpires() throws {
        let store = BrowserHandoffStore(paths: paths)
        try store.stop(reason: "requires_otp", fingerprint: "venue", now: 100)
        XCTAssertEqual(store.unsupported(fingerprint: "venue", now: 200), "requires_otp")
        XCTAssertNil(store.unsupported(fingerprint: "another", now: 200))
        XCTAssertNil(store.unsupported(fingerprint: nil, now: 200))
        XCTAssertNil(store.unsupported(fingerprint: "venue", now: 99))
        XCTAssertNil(store.unsupported(fingerprint: "venue", now: 86_501))
    }
    func testCaptureSameSecondKeepsBothAttemptsAndPrivatePermissions() throws {
        let evidence = EvidenceStore(paths: paths)
        let url = URL(string: "https://portal.example/login?token=SENTINEL_TOKEN")!
        let hop = PortalHop(
            request: HTTPRequest(url: url, method: "POST"),
            response: HTTPResponse(
                url: url, status: 200, headers: ["Set-Cookie": "SENTINEL_COOKIE"],
                body: Data("SENTINEL_BODY".utf8)))
        let attempt = PortalAttempt(
            outcome: .failed, reason: "form_rejected", portalURL: url, hops: [hop])
        let first = try XCTUnwrap(
            evidence.capture(attempt, fingerprint: "../../venue", successful: false, now: 100))
        let second = try XCTUnwrap(
            evidence.capture(attempt, fingerprint: "../../venue", successful: false, now: 100))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            first.deletingLastPathComponent().deletingLastPathComponent(), paths.captures)
        XCTAssertEqual(try mode(first), 0o700)
        XCTAssertEqual(
            try mode(first.deletingLastPathComponent()), 0o700,
            "The venue directory must not disclose capture names to other users")
        for file in try FileManager.default.contentsOfDirectory(
            at: first, includingPropertiesForKeys: nil)
        { XCTAssertEqual(try mode(file), 0o600) }
        let safe = try String(
            contentsOf: first.appendingPathComponent("safe_report.json"), encoding: .utf8)
        for secret in ["SENTINEL_TOKEN", "SENTINEL_COOKIE", "SENTINEL_BODY", "../../venue"] {
            XCTAssertFalse(safe.contains(secret), secret)
        }
        XCTAssertEqual(
            try String(contentsOf: first.appendingPathComponent("01_body.html"), encoding: .utf8),
            "SENTINEL_BODY")
    }
    func testFailureCaptureDoesNotSuppressFirstSuccessfulCapture() throws {
        let evidence = EvidenceStore(paths: paths)
        let attempt = PortalAttempt(
            outcome: .submitted, portalURL: URL(string: "https://portal.example/")!)
        XCTAssertNotNil(
            evidence.capture(attempt, fingerprint: "venue", successful: false, now: 100))
        XCTAssertTrue(evidence.hasCapture("venue"))
        XCTAssertFalse(evidence.hasCapture("venue", successful: true))
        XCTAssertNotNil(evidence.capture(attempt, fingerprint: "venue", successful: true, now: 101))
        XCTAssertTrue(evidence.hasCapture("venue", successful: true))
    }
    func testCaptureKeysCannotEscapeEvidenceRoot() {
        for key in [".", "..", "../../outside", "", "/absolute/path"] {
            let safe = EvidenceStore.safeKey(key)
            XCTAssertFalse(safe.contains("/"))
            XCTAssertFalse([".", "..", ""].contains(safe))
        }
    }
    func testCaptureStructuredFormMetadataPreservesMeaningWithoutRawSecrets() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("macos/Resources")
        let url = URL(string: "https://portal.example/login?token=SENTINEL_QUERY")!
        let body =
            "<form method='post' action='/register?token=SENTINEL_ACTION'><label>Email SENTINEL_LABEL<input name='email' type='email' required value='SENTINEL_EMAIL'></label><input type='hidden' name='csrf' value='SENTINEL_TOKEN'><input name='SENTINEL_UNKNOWN' value='SENTINEL_VALUE'></form>"
        let request = HTTPRequest(url: url)
        let response = HTTPResponse(
            url: url, status: 200,
            headers: ["Content-Type": "text/html", "Set-Cookie": "SENTINEL_COOKIE"],
            body: Data(body.utf8))
        let attempt = PortalAttempt(
            outcome: .failed, portalURL: url,
            hops: [PortalHop(request: request, response: response)])
        let capture = try XCTUnwrap(
            EvidenceStore(paths: paths, resources: resources).capture(
                attempt, fingerprint: "venue", successful: false, now: 100))
        let report = try XCTUnwrap(
            PrivateFile.object(at: capture.appendingPathComponent("safe_report.json")))
        let hops = try XCTUnwrap(report["hops"] as? [[String: Any]])
        let forms = try XCTUnwrap(hops.first?["forms"] as? [[String: Any]])
        let fields = try XCTUnwrap(forms.first?["fields"] as? [[String: Any]])
        XCTAssertEqual(forms.first?["action_path"] as? String, "/register")
        XCTAssertTrue(
            fields.contains {
                $0["name"] as? String == "email" && $0["intent"] as? String == "email"
                    && $0["required"] as? Bool == true
            })
        XCTAssertTrue(
            fields.contains { ($0["name"] as? String)?.hasPrefix("redacted-field-") == true })
        let encoded = try JSONSerialization.data(withJSONObject: report)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("SENTINEL"))
    }
    func testPortalUnavailableVerdictExpiresAfterShortRecoveryWindow() throws {
        let store = BrowserHandoffStore(paths: paths)
        try store.stop(reason: "portal_page_unavailable", fingerprint: "venue", now: 100)
        XCTAssertEqual(store.unsupported(fingerprint: "venue", now: 159), "portal_page_unavailable")
        XCTAssertNil(store.unsupported(fingerprint: "venue", now: 161))
    }
    func testStructuralReportRejectsExternalAndSymlinkPaths() throws {
        let outside = root.appendingPathComponent("external.json")
        try PrivateFile.writeJSON(["format": 1, "host": "portal.example"], to: outside)
        let evidence = EvidenceStore(paths: paths)
        XCTAssertNil(evidence.report(at: outside))
        try PrivateFile.directory(paths.journeys)
        let link = paths.journeys.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(evidence.report(at: link))
    }
    func testInvalidReportHostsFailClosed() throws {
        let evidence = EvidenceStore(paths: paths)
        for host in [
            "", "https://portal.example/", "portal.example?token=secret", "guest@example.test",
            "portal.example\nInjected", String(repeating: "x", count: 254),
        ] {
            let target = try report(["host": host])
            XCTAssertNil(evidence.report(at: target))
        }
    }
    func testFutureProgressFormatIsNotOverwrittenByOnlineRecovery() throws {
        try PrivateFile.writeJSON(
            ["format": 2, "phase": "network_check", "future_field": "preserve"], to: paths.progress)
        let before = try Data(contentsOf: paths.progress)
        EvidenceStore(paths: paths).confirmAccess(now: 100)
        XCTAssertEqual(try Data(contentsOf: paths.progress), before)
    }
    func testStructuralReportStripsSecretSentinelsAndBoundsCounts() throws {
        let target = try report([
            "provider": "SENTINEL_PROVIDER", "password": "SENTINEL_PASSWORD",
            "signature": "SENTINEL_SIGNATURE", "local_reasoning_requests": 1000,
            "local_reasoning_decisions": 2000,
            "journey": [
                "actions": 1000,
                "trace": [
                    [
                        "signature": "12345678", "action": "invalid", "elapsed_ms": 9_000_000,
                        "fields": [
                            [
                                "intent": "SENTINEL_INTENT", "type": "SENTINEL_TYPE",
                                "value": "SENTINEL_VALUE", "label": "SENTINEL_LABEL",
                            ]
                        ],
                    ]
                ],
            ],
        ])
        let value = try XCTUnwrap(EvidenceStore(paths: paths).report(at: target))
        let data = try JSONSerialization.data(withJSONObject: value)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("SENTINEL"))
        XCTAssertEqual(value["provider"] as? String, "generic")
        XCTAssertEqual(value["local_reasoning_requests"] as? Int, 12)
        XCTAssertEqual(value["local_reasoning_decisions"] as? Int, 12)
        let journey = try XCTUnwrap(value["journey"] as? [String: Any])
        XCTAssertEqual(journey["actions"] as? Int, 32)
        let trace = try XCTUnwrap(journey["trace"] as? [[String: Any]])
        XCTAssertEqual(trace.first?["elapsed_ms"] as? Int, 600000)
    }
    func testOrdinarySingleActionCountIsNotMistakenForBoolean() throws {
        let target = try report(["local_reasoning_requests": 1, "local_reasoning_decisions": 1])
        let value = try XCTUnwrap(EvidenceStore(paths: paths).report(at: target))
        XCTAssertEqual((value["journey"] as? [String: Any])?["actions"] as? Int, 1)
        XCTAssertEqual(value["local_reasoning_requests"] as? Int, 1)
        XCTAssertEqual(value["local_reasoning_decisions"] as? Int, 1)
    }
    func testReportBooleanDoesNotBecomeAnActionCount() throws {
        let target = try report(["journey": ["actions": true], "local_reasoning_requests": true])
        let value = try XCTUnwrap(EvidenceStore(paths: paths).report(at: target))
        XCTAssertEqual((value["journey"] as? [String: Any])?["actions"] as? Int, 0)
        XCTAssertEqual(value["local_reasoning_requests"] as? Int, 0)
    }
    func testAssistedAndUnsupportedMetricsRemainSeparate() throws {
        let evidence = EvidenceStore(paths: paths)
        let manual = try report(["outcome": "pending_verification"], name: "manual.json")
        _ = evidence.outcome(report: manual, verified: true, assisted: true, now: 100)
        let unsupported = try report(["outcome": "unsupported"], name: "unsupported.json")
        _ = evidence.outcome(report: unsupported, now: 100)
        evidence.staticOutcome(
            host: "portal.example", provider: "generic", fingerprint: "venue", outcome: "verified",
            firstVisit: true, now: 100)
        let counts = evidence.summary()
        XCTAssertEqual(counts["assisted_verified"], 1)
        XCTAssertEqual(counts["automatic_verified"], 1)
        XCTAssertEqual(counts["automatic_attempts"], 2)
        XCTAssertEqual(counts["automatic_eligible"], 1)
        XCTAssertEqual(counts["unsupported"], 1)
        XCTAssertTrue(evidence.seenVenue("venue"))
        XCTAssertFalse(evidence.seenVenue("other"))
    }
}

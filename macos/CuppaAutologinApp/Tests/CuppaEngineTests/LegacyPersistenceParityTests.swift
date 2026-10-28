import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

private struct FixedInspector: NetworkInspecting {
    let network: NetworkSnapshot
    func current() async -> NetworkSnapshot { network }
}
final class LegacyPersistenceParityTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    var paths: EnginePaths!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-legacy-persistence-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    var network: NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "AA:BB:CC:DD:EE:FF",
            ssid: "Synthetic Cafe", wifiInterfaces: ["en0"])
    }
    var evidence: EvidenceStore { EvidenceStore(paths: paths) }
    func testGatewayURLHandlesIPv4IPv6AndMissingAddress() {
        XCTAssertEqual(
            NativeNetworkRecovery.gatewayURL("192.0.2.1")?.absoluteString, "http://192.0.2.1/")
        XCTAssertEqual(
            NativeNetworkRecovery.gatewayURL("2001:db8::1")?.absoluteString, "http://[2001:db8::1]/"
        )
        XCTAssertNil(NativeNetworkRecovery.gatewayURL(nil))
        XCTAssertNil(NativeNetworkRecovery.gatewayURL("not-an-address"))
    }
    func testMissingIgnoreFileAndCaseInsensitiveComments() throws {
        XCTAssertNil(
            NetworkIdentity.dormancy(
                network: network, identity: PortalIdentity(values: [:]), ignoreText: ""))
        XCTAssertEqual(
            NetworkIdentity.dormancy(
                network: network, identity: PortalIdentity(values: [:]),
                ignoreText: "# comment\n\naa:bb:cc:dd:ee:ff  # home\n02:00:00:00:00:07\n"),
            "ignored_gateway")
        XCTAssertNil(
            NetworkIdentity.dormancy(
                network: NetworkSnapshot(), identity: PortalIdentity(values: [:]),
                ignoreText: "aa:bb:cc:dd:ee:ff"))
    }
    func testIgnoreCurrentAppendIsIdempotentAndLabelCannotAddAnotherRow() async throws {
        let inspector = FixedInspector(network: network)
        for _ in 0..<2 {
            let result = await EngineCLI.execute(
                arguments: ["--ignore-current", "home\nnot-another-entry"], paths: paths,
                resources: root, inspector: inspector)
            XCTAssertEqual(result.status, 0)
        }
        let lines = try String(contentsOf: paths.ignored, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("home not-another-entry"))
        XCTAssertTrue(lines[0].lowercased().hasPrefix("aa:bb:cc:dd:ee:ff"))
    }
    func testIgnoreCurrentWithoutGatewayDoesNotCreateFile() async {
        let result = await EngineCLI.execute(
            arguments: ["--ignore-current"], paths: paths, resources: root,
            inspector: FixedInspector(network: NetworkSnapshot()))
        XCTAssertEqual(result.status, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.ignored.path))
    }
    func testHotspotRangesAndInvalidAddresses() {
        for address in ["172.20.10.1", "172.20.10.15", "192.168.43.1"] {
            XCTAssertTrue(NetworkIdentity.isHotspot(address))
        }
        for address in ["172.20.10.16", "172.20.11.1", "192.168.43.2", "192.0.2.254", "not-an-ip"] {
            XCTAssertFalse(NetworkIdentity.isHotspot(address))
        }
        XCTAssertFalse(NetworkIdentity.isHotspot(nil))
    }
    func testPhonePolicyPersistenceIdempotenceAndScope() {
        let path = root.appendingPathComponent("phone_policy.json")
        let store = PhonePolicyStore(path: path)
        XCTAssertFalse(store.knows("one"))
        XCTAssertTrue(store.remember("one"))
        XCTAssertFalse(store.remember("one"))
        XCTAssertTrue(PhonePolicyStore(path: path).knows("one"))
        XCTAssertFalse(store.knows("two"))
    }
    func testEmptyAndCorruptPhonePolicyRemainUnknown() throws {
        let path = root.appendingPathComponent("phone_policy.json")
        let store = PhonePolicyStore(path: path)
        XCTAssertFalse(store.remember(""))
        XCTAssertFalse(store.knows(""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try PrivateFile.write(Data("{not json".utf8), to: path)
        XCTAssertFalse(store.knows("one"))
        try PrivateFile.writeJSON(["phone_validating_venues": [true, 1]], to: path)
        XCTAssertFalse(store.knows("one"))
    }
    func testProgressRecoveryFinishesOnceAndRoutinePollPreservesBytes() throws {
        for phase in ["network_check", "network_unavailable"] {
            evidence.progress(
                phase, title: "Checking", detail: "Previous problem",
                reason: "upstream_unavailable", newAttempt: true, now: 100)
            evidence.confirmAccess(now: 101)
            let value = try XCTUnwrap(PrivateFile.object(at: paths.progress))
            XCTAssertEqual(value["phase"] as? String, "connected")
            XCTAssertEqual(value["terminal"] as? Bool, true)
            XCTAssertNil(value["reason"])
            XCTAssertTrue((value["detail"] as? String ?? "").contains("verified"))
            XCTAssertEqual((value["events"] as? [Any])?.count, 2)
            let before = try Data(contentsOf: paths.progress)
            evidence.confirmAccess(now: 102)
            XCTAssertEqual(try Data(contentsOf: paths.progress), before)
        }
    }
    func testProgressMissingInvalidFutureAndPortalPhasesArePreserved() throws {
        evidence.confirmAccess(now: 100)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.progress.path))
        for text in ["not json", "[]", "{\"format\":2,\"phase\":\"network_check\"}"] {
            try PrivateFile.write(Data(text.utf8), to: paths.progress)
            evidence.confirmAccess(now: 100)
            XCTAssertEqual(try String(contentsOf: paths.progress, encoding: .utf8), text)
        }
        for phase in ["browser_handoff", "connected", "stopped"] {
            evidence.progress(phase, title: "Preserve", actions: 3, newAttempt: true, now: 100)
            let before = try Data(contentsOf: paths.progress)
            evidence.confirmAccess(now: 101)
            XCTAssertEqual(try Data(contentsOf: paths.progress), before)
        }
    }
    func testProgressBoundsHistoryResetsAttemptAndRejectsArbitraryReason() throws {
        for _ in 0..<40 { evidence.progress("static_form", title: "Step", now: 100) }
        evidence.progress(
            "browser_handoff", title: "Browser", reason: "requires_browser", actions: 2, now: 100)
        var value = try XCTUnwrap(PrivateFile.object(at: paths.progress))
        XCTAssertEqual((value["events"] as? [Any])?.count, 32)
        XCTAssertEqual(value["terminal"] as? Bool, false)
        XCTAssertEqual(value["actions"] as? Int, 2)
        evidence.progress(
            "stopped", title: "Stopped", reason: "https://host/?token=secret", newAttempt: true,
            now: 101)
        value = try XCTUnwrap(PrivateFile.object(at: paths.progress))
        XCTAssertEqual((value["events"] as? [Any])?.count, 1)
        XCTAssertNil(value["reason"])
        XCTAssertFalse(try String(contentsOf: paths.progress, encoding: .utf8).contains("secret"))
    }
    func testHandoffNullShapeReplacementAndDeadlineAfterSlowAttempt() throws {
        let store = BrowserHandoffStore(paths: paths)
        try store.write(
            attempt: PortalAttempt(
                outcome: .browser, reason: "requires_browser",
                portalURL: URL(string: "https://portal.example/first")!), network: network,
            fingerprint: nil, cookies: [], capturedPath: nil, firstVisit: true, now: 100)
        var record = try XCTUnwrap(PrivateFile.object(at: paths.handoff))
        XCTAssertTrue(record["venue_fingerprint"] is NSNull)
        XCTAssertTrue(record["captured_html_path"] is NSNull)
        XCTAssertEqual(record["written_at"] as? Double, 100)
        XCTAssertEqual(record["deadline"] as? Double, 190)
        try store.write(
            attempt: PortalAttempt(
                outcome: .browser, reason: "requires_browser",
                portalURL: URL(string: "https://portal.example/second")!), network: network,
            fingerprint: "second", cookies: [], capturedPath: root, firstVisit: false, now: 110)
        record = try XCTUnwrap(PrivateFile.object(at: paths.handoff))
        XCTAssertEqual(record["portal_url"] as? String, "https://portal.example/second")
        XCTAssertEqual(record["venue_fingerprint"] as? String, "second")
    }
    func testSharedMACCorpusAndUniqueFingerprintPriority() {
        for mac in [
            "00:00:0c:9f:f0:01", "00:00:0c:9f:f0:02", "00:00:0c:07:ac:01", "00:07:b4:00:00:01",
            "00:00:5e:00:01:01",
        ] { XCTAssertTrue(NetworkIdentity.isSharedMAC(mac)) }
        for mac in [
            "a8:46:9d:00:00:01", "98:18:88:00:00:01", "00:00:0c:00:00:01", "02:00:00:00:00:01",
            "not-a-mac",
        ] { XCTAssertFalse(NetworkIdentity.isSharedMAC(mac)) }
        XCTAssertFalse(NetworkIdentity.isSharedMAC(nil))
        XCTAssertEqual(
            NetworkIdentity.fingerprint(
                NetworkSnapshot(gatewayMAC: "a8:46:9d:00:00:01", ssid: "Boots"),
                portalDomain: "eu.network-auth.com"), "a8:46:9d:00:00:01")
        XCTAssertEqual(
            NetworkIdentity.fingerprint(
                NetworkSnapshot(gatewayMAC: "00:00:0c:9f:f0:01", ssid: "Picturehouse")),
            "Picturehouse")
        XCTAssertEqual(
            NetworkIdentity.fingerprint(
                NetworkSnapshot(gatewayMAC: "00:00:0c:9f:f0:01", dhcpDomain: "btwifi.com")),
            "btwifi.com")
    }
    func testFirstVisitMetricsAndStructuralTimingRetainOnlyReviewedFields() throws {
        XCTAssertFalse(evidence.seenVenue("private-venue"))
        evidence.staticOutcome(
            host: "portal.example", provider: "generic", fingerprint: "private-venue",
            outcome: "verified", firstVisit: true, now: 100)
        XCTAssertTrue(evidence.seenVenue("private-venue"))
        XCTAssertFalse(evidence.seenVenue("other"))
        evidence.staticOutcome(
            host: "portal.example", provider: "generic", fingerprint: "private-venue",
            outcome: "verified", firstVisit: false, now: 200)
        XCTAssertEqual(evidence.summary()["first_visit_verified"], 1)
        XCTAssertEqual(evidence.summary()["returning_verified"], 1)
        let path = paths.journeys.appendingPathComponent("timing.json")
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
            ], to: path)
        let report = try XCTUnwrap(evidence.report(at: path))
        let rows = (report["journey"] as? [String: Any])?["trace"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["action"] as? String, "1234abcd")
        XCTAssertEqual(rows?.first?["elapsed_ms"] as? Int, 1234)
        XCTAssertEqual(rows?.first?["outcome"] as? String, "unchanged")
        XCTAssertFalse(
            String(decoding: try JSONSerialization.data(withJSONObject: report), as: UTF8.self)
                .contains("private@example.test"))
    }
    func testDiagnosticScrubbingAndNoUnscopedEvent() throws {
        evidence.trace(
            attempt: "same", phase: "form", title: "Found",
            detail: "https://portal.test/?token=secret user@example.com 07700900123", now: 100)
        let log = try String(contentsOf: paths.log, encoding: .utf8)
        for secret in ["secret", "user@example.com", "07700900123"] {
            XCTAssertFalse(log.contains(secret))
        }
        evidence.trace(attempt: "", phase: "probe", title: "No scope", now: 100)
        XCTAssertEqual(try String(contentsOf: paths.log, encoding: .utf8), log)
    }
}

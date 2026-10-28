import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

extension EngineFixture {
    func configure(
        initial: Internet? = nil, after: Internet? = nil, outcome: PortalAttempt.Outcome? = nil,
        reason: String? = nil, venue: String? = nil
    ) {
        if let initial {
            self.initial = initial
            afterAction = initial
        }
        if let after { afterAction = after }
        if let outcome { attempt.outcome = outcome }
        if let reason { attempt.reason = reason }
        if let venue { attempt.venue = venue }
    }
    func setNetwork(_ snapshot: NetworkSnapshot) { network = snapshot }
    func setGatewayRedirect(_ url: URL) { gatewayRedirect = url }
    func observations() -> ([URL], [String]) { (receivedURLs, receivedPhones) }
}
private actor SweepOracle {
    var calls = 0
    let result: URL?
    init(_ result: URL? = nil) { self.result = result }
    func run() -> URL? {
        calls += 1
        return result
    }
    func count() -> Int { calls }
}
private actor CommandOracle: SystemCommandRunning {
    var calls: [(String, [String])] = []
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async
        -> CommandOutput
    {
        calls.append((executable, arguments))
        return CommandOutput(status: 0, text: "")
    }
    func observed() -> [(String, [String])] { calls }
}

final class LegacyEngineParityTests: XCTestCase, @unchecked Sendable {
    var root: URL!
    var paths: EnginePaths!
    var clock: EngineClock!
    var network: NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest", wifiInterfaces: ["en0"])
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-legacy-engine-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
        clock = EngineClock()
        try identity()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    func identity(extra: String = "") throws {
        try PrivateFile.write(
            Data(
                "FAKE_FIRST_NAME=Synthetic\nFAKE_LAST_NAME=Guest\nFAKE_EMAIL=synthetic@example.test\nFAKE_DOB=1990-01-01\nFAKE_POSTCODE=SW1A 1AA\nFAKE_PHONE=07700900123\nSIGNUP_PASSWORD=synthetic\nENABLE_REASSOC_FALLBACK=true\n\(extra)"
                    .utf8), to: paths.identity)
    }
    private func engine(
        _ fixture: EngineFixture, sweep: SweepOracle = SweepOracle(), discover: URL? = nil,
        diagnosis: NetworkDiagnosis = NetworkDiagnosis(evidence: ["reason": "upstream_unavailable"])
    ) -> CuppaEngine {
        let clock = clock!
        return CuppaEngine(
            paths: paths, resources: root, inspector: fixture, clientFactory: { _ in fixture },
            portalFactory: { _ in fixture }, diagnose: { _, _, _ in diagnosis },
            now: { clock.now() }, sleep: { clock.sleep($0) }, reassociate: { clock.recovery($0) },
            discover: { _ in discover }, forensics: { _, _, _, _ in await sweep.run() })
    }
    private func run(_ fixture: EngineFixture, sweep: SweepOracle = SweepOracle()) async {
        PrivateFile.remove(paths.handoff)
        _ = await engine(fixture, sweep: sweep).once(retry: false)
    }
    func notifications() -> [String] {
        ((try? String(contentsOf: paths.log, encoding: .utf8)) ?? "").components(
            separatedBy: .newlines
        ).filter { $0.contains("activity notification:") }
    }
    func captures() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: paths.captures.appendingPathComponent(EvidenceStore.safeKey(network.gatewayMAC!)),
            includingPropertiesForKeys: nil)) ?? []
    }

    func testOnlineJoinTimestampAndRoutinePollAreDistinct() async throws {
        let fixture = EngineFixture(network: network, initial: .online)
        await run(fixture)
        clock.setNow(1030)
        await run(fixture)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.fields["last_check_ts"] as? Double, 1030)
        XCTAssertEqual(state.fields["last_connection_ts"] as? Double, 1000)
        XCTAssertTrue(notifications().isEmpty)
    }
    func testEnginePersistsFingerprintAndLandingVenue() async {
        let fixture = EngineFixture(network: network)
        await fixture.configure(venue: "Synthetic Cafe")
        await run(fixture)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.fields["gateway_mac"] as? String, network.gatewayMAC)
        XCTAssertEqual(state.fields["portal_domain"] as? String, "portal.example")
        XCTAssertEqual(state.fields["ssid"] as? String, network.ssid)
        XCTAssertEqual(state.fields["venue"] as? String, "Synthetic Cafe")
    }
    func testVerifiedGrantSurvivesStaleWebsheet() async {
        var snapshot = network
        snapshot.captiveHint = true
        snapshot.captiveStage = "Websheet"
        await run(EngineFixture(network: snapshot))
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertEqual(EngineState.load(paths).failures, 0)
    }
    func testCaptiveThenSuccessNotificationsFireOnceAndHealthyPollIsQuiet() async {
        let fixture = EngineFixture(network: network, initial: .online)
        await run(fixture)
        await fixture.configure(initial: .captive, after: .online)
        await run(fixture)
        XCTAssertEqual(notifications().count, 2)
        if notifications().count == 2 {
            XCTAssertTrue(notifications()[0].contains("portal detected"))
            XCTAssertTrue(notifications()[1].contains("back online"))
        }
        await fixture.configure(initial: .online)
        await run(fixture)
        XCTAssertEqual(notifications().count, 2)
    }
    func testNoNetworkNeverSendsActivityNotification() async {
        await run(EngineFixture(network: network, initial: .unreachable))
        XCTAssertTrue(notifications().isEmpty)
    }
    func testUnsupportedRecoveryNotifiesOnceThenHealthyPollIsQuiet() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "captcha_required")
        await run(fixture)
        let before = notifications().count
        await fixture.configure(initial: .online)
        await run(fixture)
        await run(fixture)
        XCTAssertEqual(notifications().count, before + 1)
        XCTAssertTrue(notifications().last?.contains("back online") == true)
    }
    func testIgnoredInterludeDoesNotBecomeRecoveryNotification() async throws {
        let fixture = EngineFixture(network: network, initial: .online)
        await run(fixture)
        try PrivateFile.write(Data("\(network.gatewayMAC!) # synthetic\n".utf8), to: paths.ignored)
        await run(fixture)
        PrivateFile.remove(paths.ignored)
        await run(fixture)
        XCTAssertTrue(notifications().isEmpty)
    }
    func testOnlineRecoveryTraceAndProgressAreNotRepeatedByHealthyPoll() async throws {
        try EngineState(fields: ["last_result": "UNSUPPORTED", "gateway_mac": network.gatewayMAC!])
            .save(paths)
        EvidenceStore(paths: paths).progress("network_check", title: "Checking", now: 1000)
        let fixture = EngineFixture(network: network, initial: .online)
        await run(fixture)
        let log = try String(contentsOf: paths.log, encoding: .utf8)
        XCTAssertTrue(log.contains("Internet access confirmed"))
        let complete = try Data(contentsOf: paths.progress)
        await run(fixture)
        XCTAssertEqual(try Data(contentsOf: paths.progress), complete)
        XCTAssertEqual(
            try String(contentsOf: paths.log, encoding: .utf8).components(
                separatedBy: "DIAGNOSTIC_STEP"
            ).count, log.components(separatedBy: "DIAGNOSTIC_STEP").count)
    }
    func testDiagnosisNetworkChangeDiscardsEvidenceAndRedirect() async {
        let fixture = EngineFixture(network: network, initial: .unreachable)
        await fixture.changeDuringProbe()
        let diagnosis = NetworkDiagnosis(
            evidence: ["reason": "portal_discovered"],
            portalURL: URL(string: "https://old.example/login"))
        _ = await engine(fixture, diagnosis: diagnosis).once(retry: false)
        XCTAssertNil(EngineState.load(paths).fields["network_diagnostic"])
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 0)
    }
    func testConsecutiveFailureIncrementThenSuccessResets() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        await run(fixture)
        XCTAssertEqual(EngineState.load(paths).failures, 1)
        await run(fixture)
        XCTAssertEqual(EngineState.load(paths).failures, 2)
        await fixture.configure(after: .online, outcome: .submitted, reason: "")
        await run(fixture)
        XCTAssertEqual(EngineState.load(paths).failures, 0)
    }
    func testOrdinaryFailureSweepsImmediatelyAndSuccessNeverSweeps() async {
        let sweep = SweepOracle()
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        await run(fixture, sweep: sweep)
        let first = await sweep.count()
        XCTAssertEqual(first, 1)
        await fixture.configure(after: .online, outcome: .submitted)
        await run(fixture, sweep: sweep)
        let after = await sweep.count()
        XCTAssertEqual(after, 1)
    }
    func testTransientFailureSweepsOnlyAfterSecondFailure() async {
        let sweep = SweepOracle()
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed,
            reason: "portal_transport_unavailable")
        await run(fixture, sweep: sweep)
        let first = await sweep.count()
        XCTAssertEqual(first, 0)
        await run(fixture, sweep: sweep)
        let second = await sweep.count()
        XCTAssertEqual(second, 1)
    }
    func testNilSweepDoesNotCrashOrInventHandoff() async {
        await run(
            EngineFixture(
                network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected"))
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testForensicJSAndCNARecoveryProduceScopedBrowserHandoff() async throws {
        for cna in [false, true] {
            let directory = root.appendingPathComponent(cna ? "cna" : "js")
            let url = "https://wifi.wireless-social.com/login?token=synthetic"
            let summary: [String: Any] =
                cna
                ? ["cna_portal_url": url]
                : ["portal_final_url": url, "portal_final_analysis": ["looks_js_rendered": true]]
            try PrivateFile.writeJSON(summary, to: directory.appendingPathComponent("summary.json"))
            await run(
                EngineFixture(
                    network: network, afterAction: .captive, outcome: .failed,
                    reason: "form_rejected"), sweep: SweepOracle(directory))
            let record = PrivateFile.object(at: paths.handoff)
            XCTAssertEqual(record?["portal_url"] as? String, url)
            XCTAssertEqual(record?["network_interface"] as? String, "en0")
            XCTAssertEqual(record?["network_gateway_ip"] as? String, "192.0.2.1")
            XCTAssertEqual(record?["venue_fingerprint"] as? String, network.gatewayMAC)
        }
    }
    func testSuccessCapturedOnceButEveryFailureStillCaptured() async {
        let fixture = EngineFixture(network: network)
        await run(fixture)
        XCTAssertEqual(captures().count, 1)
        await run(fixture)
        XCTAssertEqual(captures().count, 1)
        await fixture.configure(after: .captive, outcome: .failed, reason: "form_rejected")
        await run(fixture)
        await run(fixture)
        XCTAssertEqual(captures().count, 3)
    }
    func testGatewayAndCNADiscoveryReachPortalBeforeProviderResolution() async {
        let expected = URL(string: "https://wifi.wireless-social.com/login?magic=synthetic")!
        for gateway in [false, true] {
            let fixture = EngineFixture(network: network, initial: .captiveBare)
            if gateway { await fixture.setGatewayRedirect(expected) }
            _ = await engine(fixture, discover: gateway ? nil : expected).once(retry: false)
            let observed = await fixture.observations()
            XCTAssertEqual(observed.0, [expected])
            XCTAssertEqual(
                EngineState.load(paths).fields["portal_domain"] as? String,
                "wifi.wireless-social.com")
        }
    }
    func testUnsupportedCaptureAndNotificationOncePerFingerprintAndNewVenueRearms() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "captcha_required")
        await run(fixture)
        await run(fixture)
        await run(fixture)
        XCTAssertEqual(captures().count, 1)
        XCTAssertEqual(notifications().count, 2)
        var other = network
        other.gatewayMAC = "02:00:00:00:00:99"
        await fixture.setNetwork(other)
        await run(fixture)
        XCTAssertEqual(notifications().count, 4)
    }
    func testAllReviewedUnsupportedReasonsRemainTerminalWithoutRadioRecovery() async {
        for reason in [
            "captcha_required", "voucher_or_venue_credential_required", "sponsor_approval_required",
            "government_identity_required", "marketing_consent_required", "social_login_required",
            "persona_phone_rejected",
        ] {
            PrivateFile.remove(paths.state)
            PrivateFile.remove(paths.unsupported)
            await run(EngineFixture(network: network, outcome: .unsupported, reason: reason))
            XCTAssertEqual(EngineState.load(paths).result, "UNSUPPORTED", reason)
            XCTAssertEqual(EngineState.load(paths).failures, 0)
        }
        XCTAssertTrue(clock.counts().recoveries.isEmpty)
    }
    func testUnavailablePageFollowupKeepsActionableTerminalProgress() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "portal_page_unavailable")
        await run(fixture)
        await run(fixture)
        let record = try XCTUnwrap(PrivateFile.object(at: paths.progress))
        XCTAssertEqual(record["terminal"] as? Bool, true)
        XCTAssertEqual(record["title"] as? String, "Wi-Fi sign-in page unavailable")
        XCTAssertTrue((record["detail"] as? String ?? "").contains("Ask the venue"))
        XCTAssertTrue(clock.counts().recoveries.isEmpty)
    }
    func testAndroidHotspotAndUserOptOut() async throws {
        var snapshot = network
        snapshot.gatewayIP = "192.168.43.1"
        let fixture = EngineFixture(network: snapshot, initial: .online)
        await run(fixture)
        let asleep = await fixture.stats()
        XCTAssertEqual(asleep.requests, 0)
        try identity(extra: "IGNORE_HOTSPOTS=false\n")
        await run(fixture)
        let awake = await fixture.stats()
        XCTAssertEqual(awake.requests, 1)
    }
    func testReassociationRateLimitRearmsAfterSuccessAndWindow() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        for timestamp in [1000.0, 1200, 1700] {
            clock.setNow(timestamp)
            await run(fixture)
            await run(fixture)
            await fixture.configure(after: .online, outcome: .submitted)
            await run(fixture)
            await fixture.configure(after: .captive, outcome: .failed)
        }
        XCTAssertEqual(clock.counts().recoveries, ["en0", "en0"])
        XCTAssertEqual(EngineState.load(paths).fields["last_reassoc_ts"] as? Double, 1700)
    }
    func testIdentityDisablesReassociation() async throws {
        try identity(extra: "ENABLE_REASSOC_FALLBACK=false\n")
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        await run(fixture)
        await run(fixture)
        XCTAssertTrue(clock.counts().recoveries.isEmpty)
    }
    func testInjectedPowerCycleUsesOffWaitOnWithoutRealRadio() async {
        let commands = CommandOracle()
        let clock = clock!
        await NativeNetworkRecovery(commands: commands, sleep: { clock.sleep($0) }).reassociate(
            "en0")
        let calls = await commands.observed()
        XCTAssertEqual(calls.map { $0.0 }, ["/usr/sbin/networksetup", "/usr/sbin/networksetup"])
        XCTAssertEqual(
            calls.map { $0.1 },
            [["-setairportpower", "en0", "off"], ["-setairportpower", "en0", "on"]])
        XCTAssertEqual(clock.counts().sleeps, [3])
    }
    func testFastRetryStopsAfterRecoveredThirdCycle() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        let clock = clock!
        let engine = CuppaEngine(
            paths: paths, resources: root, inspector: fixture, clientFactory: { _ in fixture },
            portalFactory: { _ in fixture },
            diagnose: { _, _, _ in NetworkDiagnosis(evidence: [:]) }, now: { clock.now() },
            sleep: { seconds in
                clock.sleep(seconds)
                if clock.now() >= 1012 { await fixture.configure(initial: .online) }
            }, reassociate: { _ in }, discover: { _ in nil }, forensics: { _, _, _, _ in nil })
        _ = await engine.once()
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertEqual(clock.counts().sleeps, [6, 6])
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 2)
    }
    func testPhoneHistoryDoesNotReplacePersonaAcrossRevisits() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "persona_phone_rejected")
        await run(fixture)
        PrivateFile.remove(paths.unsupported)
        await run(fixture)
        let observed = await fixture.observations()
        XCTAssertEqual(observed.1, ["07700900123", "07700900123"])
    }
    func testBrowserResultClearsHandoffAndPersistsRequestedVenueAndTimes() async throws {
        try EngineState(fields: [
            "gateway_mac": network.gatewayMAC!, "portal_domain": "portal.example",
            "last_result": "CAPTIVE", "consecutive_failures": 3,
        ]).save(paths)
        try PrivateFile.writeJSON([:], to: paths.handoff)
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, venue: "Synthetic Cafe")
        XCTAssertEqual(result, 0)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.result, "ONLINE")
        XCTAssertEqual(state.failures, 0)
        XCTAssertEqual(state.fields["venue"] as? String, "Synthetic Cafe")
        XCTAssertEqual(state.fields["last_login_ts"] as? Double, 1000)
        XCTAssertEqual(state.fields["last_connection_ts"] as? Double, 1000)
        XCTAssertEqual(state.fields["ssid"] as? String, network.ssid)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testSSIDChangeWithoutGatewayClearsOldVenue() async throws {
        try EngineState(fields: [
            "ssid": "Old SSID", "venue": "Old venue", "portal_domain": "old.example",
            "last_result": "ONLINE",
        ]).save(paths)
        let snapshot = NetworkSnapshot(interface: "en0", ssid: "New SSID", wifiInterfaces: ["en0"])
        await run(EngineFixture(network: snapshot, initial: .online))
        let state = EngineState.load(paths)
        XCTAssertNil(state.fields["venue"])
        XCTAssertNil(state.fields["portal_domain"])
        XCTAssertEqual(state.fields["ssid"] as? String, "New SSID")
    }
    func testPortalTransportFailureProducesActionableCapture() async throws {
        await run(
            EngineFixture(
                network: network, afterAction: .captive, outcome: .failed,
                reason: "portal_transport_unavailable"))
        XCTAssertEqual(EngineState.load(paths).failures, 1)
        let capture = try XCTUnwrap(captures().first)
        XCTAssertEqual(
            PrivateFile.object(at: capture.appendingPathComponent("diagnostic.json"))?[
                "failure_reason"] as? String, "portal_transport_unavailable")
    }
    func testSilentGatewayDiscoveryFallsBackWithoutCrashing() async {
        let fixture = EngineFixture(network: network, initial: .captiveBare)
        _ = await engine(fixture).once(retry: false)
        let urls = await fixture.observations().0
        XCTAssertEqual(urls.first, ConnectivityProbe.appleURL)
    }
    func testZeroActionCaptiveCandidateRoutesToBrowserWithCapture() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .submitted, actionCount: 0)
        await run(fixture)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertNotNil(PrivateFile.object(at: paths.handoff))
        XCTAssertEqual(captures().count, 1)
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
    }
    func testReviewedMerakiHandoffPreservesReasonAndSuppressesDuplicateAction() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .browser,
            reason: "meraki_grant_transport_ambiguous")
        await run(fixture)
        _ = await engine(fixture).once(retry: false)
        XCTAssertEqual(
            PrivateFile.object(at: paths.handoff)?["reason"] as? String,
            "meraki_grant_transport_ambiguous")
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
    }
    func testSuccessAfterBrowserJourneyClearsStaleHandoff() async {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .browser, reason: "js_render")
        await run(fixture)
        XCTAssertNotNil(PrivateFile.object(at: paths.handoff))
        await fixture.configure(initial: .online)
        _ = await engine(fixture).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
    }
    func testUnsupportedDecisionCannotCrossGatewayOnEngineCycle() async throws {
        try BrowserHandoffStore(paths: paths).stop(
            reason: "captcha_required", fingerprint: "02:00:00:00:00:99", now: 1000)
        let fixture = EngineFixture(network: network)
        await run(fixture)
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
    }
    func testBrowserCompletionRejectsUnknownGateway() async {
        let fixture = EngineFixture(
            network: NetworkSnapshot(
                interface: "en0", ssid: "Synthetic Guest", wifiInterfaces: ["en0"]),
            initial: .online)
        let status = await engine(fixture).completeBrowser(fingerprint: "unknown")
        XCTAssertEqual(status, 4)
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
    }

}

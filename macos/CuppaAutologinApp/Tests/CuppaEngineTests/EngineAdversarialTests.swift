import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

actor EngineFixture: HTTPClient, NetworkInspecting, PortalHandling {
    enum Internet: Sendable {
        case captive, online, appleOnly, unreachable, delayedOnline, captiveBare
    }
    var network: NetworkSnapshot
    var initial: Internet
    var afterAction: Internet
    var attempt: PortalAttempt
    var receivedURLs: [URL] = []
    var receivedPhones: [String] = []
    var gatewayRedirect: URL?
    var actions = 0
    var requests: [HTTPRequest] = []
    var switchAfterAction = false
    var switchDuringProbe = false
    init(
        network: NetworkSnapshot, initial: Internet = .captive, afterAction: Internet = .online,
        outcome: PortalAttempt.Outcome = .submitted, reason: String = "", actionCount: Int = 1
    ) {
        self.network = network
        self.initial = initial
        self.afterAction = afterAction
        attempt = PortalAttempt(
            outcome: outcome, reason: reason,
            portalURL: URL(string: "https://portal.example/login")!, actions: actionCount,
            signature: String(repeating: "a", count: 64))
    }
    func current() async -> NetworkSnapshot { network }
    func changeAfterAction() { switchAfterAction = true }
    func changeDuringProbe() { switchDuringProbe = true }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        var mode = actions > 0 ? afterAction : initial
        if mode == .delayedOnline {
            mode =
                requests.filter { $0.url.host == "captive.apple.com" }.count >= 3
                ? .online : .captive
        }
        if switchDuringProbe { network.gatewayMAC = "02:00:00:00:00:ff" }
        if mode == .unreachable { throw URLError(.notConnectedToInternet) }
        if request.url.host == "192.0.2.1", let gatewayRedirect {
            return HTTPResponse(
                url: request.url, status: 302, headers: ["Location": gatewayRedirect.absoluteString]
            )
        }
        if request.url.host == "captive.apple.com" {
            if mode == .online || mode == .appleOnly {
                return HTTPResponse(
                    url: request.url, status: 200,
                    body: Data("<html><body>Success</body></html>".utf8))
            }
            if mode == .captiveBare {
                return HTTPResponse(
                    url: request.url, status: 200, body: Data("<form>Portal</form>".utf8))
            }
            return HTTPResponse(
                url: request.url, status: 302, headers: ["Location": "https://portal.example/login"]
            )
        }
        if request.url.host == "connectivitycheck.gstatic.com" {
            return HTTPResponse(
                url: request.url, status: mode == .online ? 204 : 302,
                headers: mode == .online ? [:] : ["Location": "https://portal.example/login"])
        }
        throw URLError(.unsupportedURL)
    }
    func cookies() async -> [PortalCookie] {
        [PortalCookie(name: "session", value: "synthetic-secret", domain: "portal.example")]
    }
    func login(url: URL, identity: PortalIdentity, network: NetworkSnapshot) async -> PortalAttempt
    {
        receivedURLs.append(url)
        receivedPhones.append(identity.phone)
        actions += 1
        if switchAfterAction { self.network.gatewayMAC = "02:00:00:00:00:ff" }
        return attempt
    }
    func stats() -> (requests: Int, actions: Int) { (requests.count, actions) }
}

final class EngineClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = 1000.0
    private var sleeps: [Double] = []
    private var recoveries: [String] = []
    func now() -> Double { lock.withLock { instant } }
    func sleep(_ seconds: Double) {
        lock.withLock {
            instant += seconds
            sleeps.append(seconds)
        }
    }
    func recovery(_ interface: String) { lock.withLock { recoveries.append(interface) } }
    func setNow(_ seconds: Double) { lock.withLock { instant = seconds } }
    func counts() -> (sleeps: [Double], recoveries: [String]) {
        lock.withLock { (sleeps, recoveries) }
    }
}

final class EngineAdversarialTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var paths: EnginePaths!
    private var clock: EngineClock!
    private var network: NetworkSnapshot {
        NetworkSnapshot(
            interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
            ssid: "Synthetic Guest", dhcpDomain: "guest.example", wifiInterfaces: ["en0"])
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-engine-" + UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("logs/engine.log"))
        clock = EngineClock()
        try identity()
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func identity(extra: String = "") throws {
        try PrivateFile.write(
            Data(
                "FAKE_FIRST_NAME=Synthetic\nFAKE_LAST_NAME=Guest\nFAKE_EMAIL=synthetic@example.test\nFAKE_DOB=1990-01-01\nFAKE_POSTCODE=SW1A 1AA\nFAKE_PHONE=07700900123\nSIGNUP_PASSWORD=synthetic-password\n\(extra)"
                    .utf8), to: paths.identity)
    }
    private func engine(
        _ fixture: EngineFixture,
        diagnosis: NetworkDiagnosis = NetworkDiagnosis(evidence: ["reason": "upstream_unavailable"])
    ) -> CuppaEngine {
        let clock = clock!
        return CuppaEngine(
            paths: paths, resources: root, inspector: fixture,
            clientFactory: { _ in fixture }, portalFactory: { _ in fixture },
            diagnose: { _, _, _ in diagnosis }, now: { clock.now() },
            sleep: { seconds in clock.sleep(seconds) },
            reassociate: { interface in clock.recovery(interface) }, discover: { _ in nil },
            forensics: { _, _, _, _ in nil })
    }
    private func seededState() throws {
        try EngineState(fields: [
            "gateway_mac": network.gatewayMAC!, "ssid": network.ssid!,
            "dhcp_domain": network.dhcpDomain!, "portal_domain": "portal.example",
            "last_result": "CAPTIVE", "consecutive_failures": 3,
        ]).save(paths)
    }
    private func browserReport(assisted: Bool = false) throws -> URL {
        let url = paths.journeys.appendingPathComponent("browser.json")
        try PrivateFile.writeJSON(
            [
                "format": 1, "host": "portal.example", "provider": "generic",
                "source": assisted ? "assisted" : "automatic", "outcome": "pending_verification",
                "signature": String(repeating: "a", count: 64),
                "journey": ["actions": 1, "trace": []],
            ], to: url)
        return url
    }

    func testOrdinaryOnlineCheckDoesNotEarnAutomaticLoginCredit() async throws {
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).once(retry: false)
        XCTAssertEqual(result, 0)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.result, "ONLINE")
        XCTAssertNil(state.fields["last_login_ts"])
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 0)
        XCTAssertEqual(stats.requests, 1)
    }
    func testSubmittedActionRequiresIndependentTwoEndpointVerification() async throws {
        let fixture = EngineFixture(network: network)
        let result = await engine(fixture).once(retry: false)
        XCTAssertEqual(result, 0)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.result, "ONLINE")
        XCTAssertEqual(state.fields["last_login_gateway_mac"] as? String, network.gatewayMAC)
        XCTAssertNotNil(state.fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 1)
        let stats = await fixture.stats()
        XCTAssertEqual(stats.requests, 3)
        XCTAssertEqual(stats.actions, 1)
    }
    func testZeroActionSubmissionBecomesOrdinaryRecoveryWithoutCreditOrLearning() async throws {
        let fixture = EngineFixture(network: network, actionCount: 0)
        let result = await engine(fixture).once(retry: false)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testAcceptedStaticGrantSettlesBeforeBrowserHandoffWithoutDuplicateAction() async throws {
        let fixture = EngineFixture(network: network, afterAction: .delayedOnline)
        let result = await engine(fixture).once(retry: false)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
        XCTAssertTrue(clock.counts().sleeps.contains(2))
    }
    func testAppleOnlyAfterActionCannotBecomeOnline() async throws {
        let fixture = EngineFixture(network: network, afterAction: .appleOnly)
        let result = await engine(fixture).once(retry: false)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(
            PrivateFile.object(at: paths.handoff)?["reason"] as? String,
            "submission_accepted_but_portal_remains")
    }
    func testExplicitPortalRejectionCannotEarnCreditFromIndependentOnline() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .online, outcome: .failed, reason: "form_rejected")
        _ = await engine(fixture).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 0)
    }
    func testChangedGatewayAfterPortalActionDiscardsSuccessAndLearning() async throws {
        let fixture = EngineFixture(network: network)
        await fixture.changeAfterAction()
        _ = await engine(fixture).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "UNKNOWN")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testChangedGatewayDuringInitialProbeDiscardsOldRedirect() async throws {
        let fixture = EngineFixture(network: network)
        await fixture.changeDuringProbe()
        _ = await engine(fixture).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "UNKNOWN")
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 0)
    }
    func testIgnoredGatewayNeverSendsProbeOrPortalAction() async throws {
        try PrivateFile.write(
            Data("\(network.gatewayMAC!) # synthetic venue\n".utf8), to: paths.ignored)
        let fixture = EngineFixture(network: network)
        _ = await engine(fixture).once()
        XCTAssertEqual(EngineState.load(paths).result, "IGNORED")
        let stats = await fixture.stats()
        XCTAssertEqual(stats.requests, 0)
        XCTAssertEqual(stats.actions, 0)
    }
    func testPersonalHotspotAndKnownNonWifiRouteAreDormant() async throws {
        var hotspot = network
        hotspot.gatewayIP = "172.20.10.1"
        let first = EngineFixture(network: hotspot)
        _ = await engine(first).once()
        XCTAssertEqual(EngineState.load(paths).result, "IGNORED")
        var ethernet = network
        ethernet.interface = "en5"
        let second = EngineFixture(network: ethernet)
        _ = await engine(second).once()
        let a = await first.stats()
        let b = await second.stats()
        XCTAssertEqual(a.requests + b.requests, 0)
    }
    func testInterfaceEnumerationFailureDoesNotInventDormancy() async throws {
        var unknown = network
        unknown.wifiInterfaces = []
        let fixture = EngineFixture(network: unknown, initial: .online)
        _ = await engine(fixture).once()
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
    }
    func testNoNetworkDiagnosisDoesNotAttemptFormOrResetRadio() async throws {
        try identity(extra: "ENABLE_REASSOC_FALLBACK=true\n")
        try seededState()
        let fixture = EngineFixture(network: network, initial: .unreachable)
        _ = await engine(fixture).once()
        let state = EngineState.load(paths)
        XCTAssertEqual(state.result, "NO_NETWORK")
        XCTAssertEqual(state.failures, 0)
        XCTAssertNotNil(state.fields["network_diagnostic"])
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 0)
        XCTAssertTrue(clock.counts().recoveries.isEmpty)
        XCTAssertTrue(clock.counts().sleeps.isEmpty)
    }
    func testNoDNSDiagnosisPortalContinuesNormalFlow() async throws {
        let fixture = EngineFixture(network: network, initial: .unreachable)
        let diagnosis = NetworkDiagnosis(
            evidence: ["reason": "portal_discovered"],
            portalURL: URL(string: "https://portal.example/login")!)
        _ = await engine(fixture, diagnosis: diagnosis).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNil(EngineState.load(paths).fields["network_diagnostic"])
    }
    func testRepeatedNoNetworkDiagnosisRetainsItsFirstObservation() async throws {
        let fixture = EngineFixture(network: network, initial: .unreachable)
        let sut = engine(fixture)
        _ = await sut.once()
        clock.sleep(16)
        _ = await sut.once()
        let diagnostic = try XCTUnwrap(
            EngineState.load(paths).fields["network_diagnostic"] as? [String: Any])
        XCTAssertEqual(diagnostic["consecutive_checks"] as? Int, 2)
        XCTAssertEqual(diagnostic["first_seen_at"] as? Double, 1000)
        XCTAssertEqual(diagnostic["repeated"] as? Bool, true)
    }
    func testPendingBrowserSuppressesDuplicateStaticAction() async throws {
        try seededState()
        let attempt = PortalAttempt(
            outcome: .browser, reason: "requires_browser",
            portalURL: URL(string: "https://portal.example/login")!, actions: 1,
            pendingSubmission: true)
        try BrowserHandoffStore(paths: paths).write(
            attempt: attempt, network: network, fingerprint: network.gatewayMAC, cookies: [],
            capturedPath: nil, firstVisit: true, now: clock.now())
        let fixture = EngineFixture(network: network)
        _ = await engine(fixture).once()
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 0)
        XCTAssertTrue(clock.counts().sleeps.isEmpty)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
    }
    func testUnsupportedVerdictStopsFollowupWithoutFailureOrRecovery() async throws {
        try identity(extra: "ENABLE_REASSOC_FALLBACK=true\n")
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "verification_code_required")
        let sut = engine(fixture)
        _ = await sut.once()
        _ = await sut.once()
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
        XCTAssertEqual(EngineState.load(paths).result, "UNSUPPORTED")
        XCTAssertEqual(EngineState.load(paths).failures, 0)
        XCTAssertTrue(clock.counts().recoveries.isEmpty)
        XCTAssertEqual(PrivateFile.object(at: paths.handoff)?["manual_only"] as? Bool, true)
    }
    func testPrivacyEmailUnsupportedVerdictStopsFollowup() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "privacy_email_required")
        let sut = engine(fixture)
        _ = await sut.once()
        _ = await sut.once()
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
        XCTAssertEqual(EngineState.load(paths).result, "UNSUPPORTED")
    }
    func testPhoneRejectionHistoryRetainsBaselineSchemaAndIdentity() async throws {
        let before = try Data(contentsOf: paths.identity)
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .unsupported,
            reason: "persona_phone_rejected")
        _ = await engine(fixture).once()
        let policy = try XCTUnwrap(
            PrivateFile.object(at: paths.root.appendingPathComponent("phone_policy.json")))
        XCTAssertTrue(
            (policy["phone_validating_venues"] as? [String] ?? []).contains(network.gatewayMAC!))
        XCTAssertEqual(try Data(contentsOf: paths.identity), before)
    }
    func testOrdinaryFailureRetriesWithinBudgetAndReassociatesOnlyAtThreshold() async throws {
        try identity(extra: "ENABLE_REASSOC_FALLBACK=true\n")
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        _ = await engine(fixture).once()
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 5)
        XCTAssertEqual(clock.counts().sleeps, [6, 6, 6, 6])
        XCTAssertEqual(clock.counts().recoveries, ["en0"])
        XCTAssertEqual(EngineState.load(paths).failures, 5)
        XCTAssertLessThan(clock.now(), 1030)
    }
    func testFailureGiveUpMarkerPersistsAcrossFollowupWithoutReset() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .failed, reason: "form_rejected")
        let sut = engine(fixture)
        _ = await sut.once()
        XCTAssertEqual(EngineState.load(paths).fields["last_notified_event"] as? String, "give_up")
        _ = await sut.once(retry: false)
        XCTAssertEqual(EngineState.load(paths).fields["last_notified_event"] as? String, "give_up")
        XCTAssertEqual(EngineState.load(paths).failures, 6)
    }
    func testBrowserHandoffStopsRetryAndCarriesCookie() async throws {
        let fixture = EngineFixture(
            network: network, afterAction: .captive, outcome: .browser, reason: "requires_browser")
        _ = await engine(fixture).once()
        let stats = await fixture.stats()
        XCTAssertEqual(stats.actions, 1)
        XCTAssertTrue(clock.counts().sleeps.isEmpty)
        let cookies = PrivateFile.object(at: paths.handoff)?["cookies"] as? [[String: Any]]
        XCTAssertEqual(cookies?.first?["value"] as? String, "synthetic-secret")
    }
    func testConcurrentLockOwnerSuppressesAllWork() async throws {
        let lock = try XCTUnwrap(EngineLock.acquire(paths.lock))
        let fixture = EngineFixture(network: network)
        let sut = engine(fixture)
        let result = await sut.once()
        XCTAssertEqual(result, 0)
        let completion = await sut.completeBrowser()
        XCTAssertEqual(completion, 3)
        let stats = await fixture.stats()
        XCTAssertEqual(stats.requests, 0)
        withExtendedLifetime(lock) {}
    }
    func testAssistedBrowserCompletionDoesNotEarnAutomaticCreditOrLearning() async throws {
        try seededState()
        let report = try browserReport(assisted: true)
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, report: report)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(EngineState.load(paths).result, "ONLINE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["assisted_verified"], 1)
        XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 0)
    }
    func testBrowserCompletionRejectsFingerprintBeforeAnyProbe() async throws {
        try seededState()
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).completeBrowser(fingerprint: "different")
        XCTAssertEqual(result, 4)
        let stats = await fixture.stats()
        XCTAssertEqual(stats.requests, 0)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
    }
    func testBrowserCompletionRequiresConsensusAndRecordsNotVerified() async throws {
        try seededState()
        let report = try browserReport()
        let fixture = EngineFixture(network: network, initial: .appleOnly)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, report: report)
        XCTAssertEqual(result, 2)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertEqual(PrivateFile.object(at: report)?["outcome"] as? String, "not_verified")
        XCTAssertEqual(clock.counts().sleeps, [0.5, 1.0])
    }
    func testBrowserCompletionDiscardsNetworkChangeDuringProbe() async throws {
        try seededState()
        let fixture = EngineFixture(network: network, initial: .online)
        await fixture.changeDuringProbe()
        let result = await engine(fixture).completeBrowser(fingerprint: network.gatewayMAC)
        XCTAssertEqual(result, 4)
        XCTAssertNil(EngineState.load(paths).fields["last_login_ts"])
    }
    func testVerifiedBrowserLearningRequiresMatchingHandoffSignature() async throws {
        try seededState()
        let report = try browserReport()
        let store = BrowserHandoffStore(paths: paths)
        let mismatch = PortalAttempt(
            outcome: .browser, reason: "requires_browser",
            portalURL: URL(string: "https://portal.example/login")!,
            signature: String(repeating: "b", count: 64))
        try store.write(
            attempt: mismatch, network: network, fingerprint: network.gatewayMAC, cookies: [],
            capturedPath: nil, firstVisit: true, now: clock.now())
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, report: report)
        XCTAssertEqual(result, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.learning.path))
        XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
    }
    func testVerifiedBrowserWithMatchingSignatureLearnsAndClearsPendingWork() async throws {
        try seededState()
        let report = try browserReport()
        let store = BrowserHandoffStore(paths: paths)
        let matching = PortalAttempt(
            outcome: .browser, reason: "requires_browser",
            portalURL: URL(string: "https://portal.example/login")!,
            signature: String(repeating: "a", count: 64))
        try store.write(
            attempt: matching, network: network, fingerprint: network.gatewayMAC, cookies: [],
            capturedPath: nil, firstVisit: true, now: clock.now())
        try store.stop(
            reason: "connectivity_unverified", fingerprint: network.gatewayMAC, now: clock.now())
        let fixture = EngineFixture(network: network, initial: .online)
        let result = await engine(fixture).completeBrowser(
            fingerprint: network.gatewayMAC, report: report)
        XCTAssertEqual(result, 0)
        let strategies = PrivateFile.object(at: paths.learning)?["strategies"] as? [[String: Any]]
        XCTAssertEqual(strategies?.count, 1)
        XCTAssertEqual(strategies?.first?["execution"] as? String, "browser")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.handoff.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.unsupported.path))
    }
    func testKnownUnsupportedUpdatesStateWithoutConnectivityProbe() async throws {
        try seededState()
        let fixture = EngineFixture(network: network)
        let result = await engine(fixture).markUnsupported(
            reason: "captcha_required", fingerprint: network.gatewayMAC)
        XCTAssertEqual(result, 0)
        XCTAssertEqual(EngineState.load(paths).result, "UNSUPPORTED")
        XCTAssertEqual(EngineState.load(paths).failures, 0)
        let stats = await fixture.stats()
        XCTAssertEqual(stats.requests, 0)
    }
    func testUnknownUnsupportedReasonCannotChangeState() async throws {
        try seededState()
        let fixture = EngineFixture(network: network)
        let result = await engine(fixture).markUnsupported(
            reason: "invented_reason", fingerprint: network.gatewayMAC)
        XCTAssertEqual(result, 2)
        XCTAssertEqual(EngineState.load(paths).result, "CAPTIVE")
    }
    func testUnsupportedOutcomeCannotCrossGateway() async throws {
        try seededState()
        var other = network
        other.gatewayMAC = "02:00:00:00:00:ff"
        let fixture = EngineFixture(network: other)
        let result = await engine(fixture).markUnsupported(
            reason: "captcha_required", fingerprint: network.gatewayMAC)
        XCTAssertEqual(result, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.unsupported.path))
    }
}

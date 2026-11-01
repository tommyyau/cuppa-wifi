import CuppaCore
import CuppaNetworking
import Foundation
import XCTest

@testable import CuppaEngine

final class ConnectionOrderTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var paths: EnginePaths!
    private let network = NetworkSnapshot(interface: "en0", gatewayIP: "192.0.2.1",
        gatewayMAC: "02:00:00:00:00:01", ssid: "Synthetic Guest", wifiInterfaces: ["en0"])

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
        try PrivateFile.write(Data("FAKE_FIRST_NAME=Test\nFAKE_LAST_NAME=Guest\nFAKE_EMAIL=test@example.test\nFAKE_DOB=1990-01-01\nFAKE_POSTCODE=SW1A 1AA\nFAKE_PHONE=07700900123\nSIGNUP_PASSWORD=synthetic-password".utf8), to: paths.identity)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func engine(_ fixture: EngineFixture, at timestamp: TimeInterval) -> CuppaEngine {
        CuppaEngine(paths: paths, resources: root, inspector: fixture,
            clientFactory: { _ in fixture }, portalFactory: { _ in fixture },
            diagnose: { _, _, _ in NetworkDiagnosis(evidence: ["reason": "upstream_unavailable"]) },
            now: { timestamp }, sleep: { _ in }, reassociate: { _ in }, discover: { _ in nil },
            forensics: { _, _, _, _ in nil })
    }

    func testTwoHourRenewalsPersistOneOrderAcrossEngineReloads() async throws {
        for time in [1_000.0, 8_200, 15_400] {
            let result = await engine(EngineFixture(network: network), at: time).once(retry: false)
            XCTAssertEqual(result, 0)
        }
        let result = await engine(EngineFixture(network: network, initial: .online), at: 16_400).once(retry: false)
        XCTAssertEqual(result, 0)
        let state = EngineState.load(paths)
        let order = try XCTUnwrap(state.connectionOrder)
        XCTAssertEqual(order.startedAt, 1_000)
        XCTAssertEqual(order.refillCount, 2)
        XCTAssertEqual(order.refills.map(\.timestamp), [8_200, 15_400])
        XCTAssertEqual(order.refills.map(\.previousCupSeconds), [7_200, 7_200])
        XCTAssertTrue(order.refills.allSatisfy(\.automatic))
        XCTAssertEqual(order.connectedSeconds(at: 16_400), 15_400)
        // Existing per-connection consumers (speed tests) retain their semantics.
        XCTAssertEqual(state.fields["last_connection_ts"] as? Double, 15_400)
        let log = try String(contentsOf: paths.log, encoding: .utf8)
        XCTAssertEqual(log.components(separatedBy: "\"phase\":\"refill\"").count - 1, 2)
    }

    func testBrowserRefillRequiresConsensusAndDuplicateCompletionDoesNotCount() async throws {
        _ = await engine(EngineFixture(network: network, initial: .online), at: 1_000).once(retry: false)
        let captive = EngineFixture(network: network, afterAction: .captive, outcome: .browser)
        _ = await engine(captive, at: 8_200).once(retry: false)
        let failed = await engine(EngineFixture(network: network, initial: .appleOnly), at: 8_210)
            .completeBrowser(fingerprint: network.gatewayMAC)
        XCTAssertEqual(failed, 2)
        XCTAssertEqual(EngineState.load(paths).connectionOrder?.refillCount, 0)
        let verified = await engine(EngineFixture(network: network, initial: .online), at: 8_230)
            .completeBrowser(fingerprint: network.gatewayMAC)
        XCTAssertEqual(verified, 0)
        _ = await engine(EngineFixture(network: network, initial: .online), at: 8_240)
            .completeBrowser(fingerprint: network.gatewayMAC)
        let order = try XCTUnwrap(EngineState.load(paths).connectionOrder)
        XCTAssertEqual(order.refillCount, 1)
        XCTAssertEqual(order.refills.first?.previousCupSeconds, 7_200)
        XCTAssertEqual(order.onlineSince, 8_230)
        XCTAssertEqual(order.connectedSeconds(at: 8_250), 7_220)
    }

    func testOutageFreezesTimeUntilVerifiedRecoveryWithoutAutomaticCredit() async throws {
        _ = await engine(EngineFixture(network: network, initial: .online), at: 1_000).once(retry: false)
        for time in [1_100.0, 1_200] {
            _ = await engine(EngineFixture(network: network, initial: .unreachable), at: time).once(retry: false)
        }
        let interrupted = try XCTUnwrap(EngineState.load(paths).connectionOrder)
        XCTAssertEqual(interrupted.connectedSeconds(at: 1_300), 100)
        _ = await engine(EngineFixture(network: network, initial: .online), at: 1_300).once(retry: false)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.connectionOrder?.connectedSeconds(at: 1_400), 200)
        XCTAssertEqual(state.connectionOrder?.refillCount, 1)
        XCTAssertEqual(state.connectionOrder?.refills.first?.automatic, false)
        XCTAssertNil(state.fields["last_login_ts"])
    }

    func testOneHourAssistedRefillKeepsHistoryWithoutAutomaticCredit() async throws {
        _ = await engine(EngineFixture(network: network, initial: .online), at: 1_000).once(retry: false)
        _ = await engine(EngineFixture(network: network, afterAction: .captive, outcome: .browser), at: 4_600)
            .once(retry: false)
        let stale = await engine(EngineFixture(network: network, initial: .online), at: 4_610)
            .completeBrowser(fingerprint: "another-venue", assisted: true)
        XCTAssertEqual(stale, 4)
        XCTAssertEqual(EngineState.load(paths).connectionOrder?.refillCount, 0)
        let verified = await engine(EngineFixture(network: network, initial: .online), at: 4_620)
            .completeBrowser(fingerprint: network.gatewayMAC, assisted: true)
        XCTAssertEqual(verified, 0)
        let state = EngineState.load(paths)
        XCTAssertEqual(state.connectionOrder?.refills.first?.previousCupSeconds, 3_600)
        XCTAssertEqual(state.connectionOrder?.refills.first?.automatic, false)
        XCTAssertEqual(state.connectionOrder?.startedAt, 1_000)
        XCTAssertNil(state.fields["last_login_ts"])
    }

    func testVenueChangeStartsFreshOrderButRedactedIdentityDoesNot() async throws {
        _ = await engine(EngineFixture(network: network), at: 1_000).once(retry: false)
        var redacted = network
        redacted.ssid = nil
        _ = await engine(EngineFixture(network: redacted), at: 8_200).once(retry: false)
        XCTAssertEqual(EngineState.load(paths).connectionOrder?.refillCount, 1)
        var other = network
        other.gatewayMAC = "02:00:00:00:00:02"
        other.ssid = "Another Venue"
        _ = await engine(EngineFixture(network: other), at: 9_000).once(retry: false)
        let order = try XCTUnwrap(EngineState.load(paths).connectionOrder)
        XCTAssertEqual(order.startedAt, 9_000)
        XCTAssertEqual(order.refillCount, 0)
        XCTAssertTrue(order.refills.isEmpty)
    }

    func testLegacyOnlineStateMigratesWithoutInventingEarlierRefills() async throws {
        try EngineState(fields: ["last_result": "ONLINE", "gateway_mac": network.gatewayMAC!,
            "last_connection_ts": 1_000.0, "last_check_ts": 1_100.0]).save(paths)
        _ = await engine(EngineFixture(network: network, initial: .online), at: 1_200).once(retry: false)
        let order = try XCTUnwrap(EngineState.load(paths).connectionOrder)
        XCTAssertEqual(order.startedAt, 1_000)
        XCTAssertEqual(order.connectedSeconds(at: 1_200), 200)
        XCTAssertEqual(order.refillCount, 0)
    }

    func testBoundedReceiptRetainsTotalAndCount() throws {
        var order = ConnectionOrder(startedAt: 0)
        for number in 1...70 {
            order.interrupt(at: Double(number * 100 - 10))
            order.reconnect(at: Double(number * 100), automatic: true)
        }
        let restored = try JSONDecoder().decode(ConnectionOrder.self, from: JSONEncoder().encode(order))
        XCTAssertEqual(restored.refillCount, 70)
        XCTAssertEqual(restored.refills.count, 64)
        XCTAssertEqual(restored.refills.first?.number, 7)
        XCTAssertEqual(restored.connectedSeconds(at: 7_010), 6_310)
    }
}

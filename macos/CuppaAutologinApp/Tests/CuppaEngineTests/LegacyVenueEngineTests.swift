import CuppaCore
import CuppaEngine
import CuppaNetworking
import CuppaPortals
import Foundation
import XCTest

private struct RecordedVenueResponse: Sendable {
    let url: URL
    let status: Int
    let body: String
}
private actor VenueEngineOracle: HTTPClient, NetworkInspecting {
    let entry: URL
    let responses: [RecordedVenueResponse]
    let snapshot: NetworkSnapshot
    var firstProbeDone = false
    var index = 0
    var portalRequests: [HTTPRequest] = []
    var actions = 0
    init(entry: URL, responses: [RecordedVenueResponse], snapshot: NetworkSnapshot) {
        self.entry = entry
        self.responses = responses
        self.snapshot = snapshot
    }
    func current() async -> NetworkSnapshot { snapshot }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let granted = index >= responses.count && actions > 0
        if request.url.host == "captive.apple.com",
            !(firstProbeDone && entry.host == "captive.apple.com" && index == 0)
        {
            firstProbeDone = true
            return granted
                ? HTTPResponse(url: request.url, status: 200, body: Data("Success".utf8))
                : HTTPResponse(
                    url: request.url, status: 302, headers: ["Location": entry.absoluteString])
        }
        if request.url.host == "connectivitycheck.gstatic.com" {
            return HTTPResponse(
                url: request.url, status: granted ? 204 : 302,
                headers: granted ? [:] : ["Location": entry.absoluteString])
        }
        portalRequests.append(request)
        if request.method == "POST" || index > 0 { actions += 1 }
        guard index < responses.count else { throw URLError(.badServerResponse) }
        let response = responses[index]
        index += 1
        return HTTPResponse(
            url: response.url, status: response.status, body: Data(response.body.utf8))
    }
    func observed() -> [HTTPRequest] { portalRequests }
}
final class LegacyVenueEngineTests: XCTestCase, @unchecked Sendable {
    func testFiveVenueContractsTraverseEngineAndReceiveIndependentCredit() async throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("macos/Resources")
        let document =
            try JSONSerialization.jsonObject(
                with: Data(
                    contentsOf: resources.deletingLastPathComponent().appendingPathComponent(
                        "TestFixtures/Portal/venue_contracts.json"))) as! [String: Any]
        let contracts = try XCTUnwrap(document["contracts"] as? [[String: Any]])
        XCTAssertEqual(contracts.count, 5)
        for contract in contracts {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "cuppa-venue-engine-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = EnginePaths(root: root, log: root.appendingPathComponent("engine.log"))
            let identity = PortalIdentity(values: [
                "FAKE_FIRST_NAME": "Sarah", "FAKE_LAST_NAME": "Chen",
                "FAKE_EMAIL": "fixture@example.test", "FAKE_DOB": "1990-05-16",
                "FAKE_POSTCODE": "M1 1AE", "FAKE_PHONE": "07700900123",
                "SIGNUP_PASSWORD": "synthetic",
            ])
            try PrivateFile.write(
                Data(identity.values.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").utf8),
                to: paths.identity)
            let entry = URL(string: contract["entry_url"] as! String)!
            let responses = (contract["responses"] as! [[String: Any]]).map {
                RecordedVenueResponse(
                    url: URL(string: $0["url"] as? String ?? entry.absoluteString)!,
                    status: $0["status"] as? Int ?? 200, body: $0["body"] as? String ?? "")
            }
            let oracle = VenueEngineOracle(
                entry: entry, responses: responses,
                snapshot: NetworkSnapshot(
                    interface: "en0", gatewayIP: "192.0.2.1", gatewayMAC: "02:00:00:00:00:01",
                    ssid: contract["ssid"] as? String, wifiInterfaces: ["en0"]))
            let engine = CuppaEngine(
                paths: paths, resources: resources, inspector: oracle,
                clientFactory: { _ in oracle },
                portalFactory: {
                    PortalWorkflow(client: $0, resources: resources, dataDirectory: root)
                }, diagnose: { _, _, _ in NetworkDiagnosis(evidence: [:]) }, now: { 1000 },
                sleep: { _ in }, reassociate: { _ in }, discover: { _ in nil },
                forensics: { _, _, _, _ in nil })
            _ = await engine.once(retry: false)
            let id = contract["id"] as? String ?? ""
            XCTAssertEqual(EngineState.load(paths).result, "ONLINE", id)
            XCTAssertNotNil(EngineState.load(paths).fields["last_login_ts"], id)
            XCTAssertEqual(EvidenceStore(paths: paths).summary()["automatic_verified"], 1, id)
            let requests = await oracle.observed()
            for expected in contract["expected_requests"] as! [[String: Any]] {
                let index = expected["index"] as! Int
                guard index < requests.count else {
                    XCTFail("Missing \(id) request \(index)")
                    continue
                }
                let request = requests[index]
                XCTAssertEqual(request.method, expected["method"] as? String, id)
                if let url = expected["url"] as? String {
                    XCTAssertEqual(request.url.absoluteString, url, id)
                }
                if let prefix = expected["url_prefix"] as? String {
                    XCTAssertTrue(request.url.absoluteString.hasPrefix(prefix), id)
                }
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                let fields =
                    URLComponents(string: "https://fixture.example/?" + body)?.queryItems?.reduce(
                        into: [String: String]()
                    ) { $0[$1.name] = $1.value ?? "" } ?? [:]
                let tokens = [
                    "$first_name": identity.firstName, "$last_name": identity.lastName,
                    "$email": identity.email,
                ]
                for (name, value) in expected["fields"] as? [String: String] ?? [:] {
                    XCTAssertEqual(fields[name], tokens[value] ?? value, "\(id): \(name)")
                }
                for name in expected["absent"] as? [String] ?? [] {
                    XCTAssertNil(fields[name], "\(id): \(name)")
                }
            }
        }
    }
}

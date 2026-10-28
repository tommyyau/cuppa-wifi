import CuppaCore
import CuppaPortals
import Foundation
import XCTest

private actor PortalOracle: HTTPClient {
    enum Scenario: Sendable {
        case lanPivot, publicCrossOrigin, ownGateway, otpAfterCorrection, explicitRejection,
            sixSteps, positiveSubmit
    }
    let scenario: Scenario
    var requests: [HTTPRequest] = []
    var posts = 0
    init(_ scenario: Scenario) { self.scenario = scenario }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        func page(_ html: String) -> HTTPResponse {
            HTTPResponse(url: request.url, status: 200, body: Data(html.utf8))
        }
        if request.method == "POST" {
            posts += 1
            if scenario == .explicitRejection {
                return page("{\"success\":false,\"message\":\"Registration rejected\"}")
            }
            if scenario == .otpAfterCorrection && posts == 1 {
                return page(
                    "<form method='post' action='/register'><input required type='tel' name='phone' aria-invalid='true'><input required name='otp' autocomplete='one-time-code'><button>Continue</button></form>"
                )
            }
            if scenario == .sixSteps && posts < 6 {
                return page(
                    "<form method='post' action='/step\(posts+1)'><input required type='email' name='email'><input type='hidden' name='csrf' value='token-\(posts+1)'><button name='next' value='yes'>Continue</button></form>"
                )
            }
            return page("<p>Server grant accepted</p>")
        }
        switch scenario {
        case .lanPivot:
            return page(
                "<form method='post' action='https://192.168.1.7/register'><input required type='email' name='email'><button>Connect</button></form>"
            )
        case .publicCrossOrigin:
            return page(
                "<form method='post' action='https://registration.example/guest'><input required type='email' name='email'><button>Connect</button></form>"
            )
        case .ownGateway:
            return page(
                "<form method='post' action='/register'><input required type='email' name='email'><button>Connect</button></form>"
            )
        case .otpAfterCorrection:
            return page(
                "<form method='post' action='/register'><input required type='tel' name='phone'><button>Continue</button></form>"
            )
        case .explicitRejection:
            return page(
                "<form method='post' action='/register'><input required type='email' name='email'><button>Connect</button></form>"
            )
        case .sixSteps:
            return page(
                "<form method='post' action='/step1'><input required type='email' name='email'><input type='hidden' name='csrf' value='token-1'><button name='next' value='yes'>Continue</button></form>"
            )
        case .positiveSubmit:
            return page(
                "<form method='post' action='/register'><input required type='email' name='email'><button name='back' value='1'>Back</button><button name='connect' value='1'>Connect</button></form>"
            )
        }
    }
    func submittedRequests() -> [HTTPRequest] { requests.filter { $0.method == "POST" } }
}
private actor ProviderGrantOracle: HTTPClient {
    var requests: [HTTPRequest] = []
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return HTTPResponse(
            url: request.url, status: 200, body: Data("<p>Synthetic grant accepted</p>".utf8))
    }
    func observed() -> [HTTPRequest] { requests }
}

final class IndependentPortalContractTests: XCTestCase, @unchecked Sendable {
    private var root: URL!
    private var resources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("macos/Resources")
    }
    private let identity = PortalIdentity(values: [
        "FAKE_FIRST_NAME": "Synthetic", "FAKE_LAST_NAME": "Guest",
        "FAKE_EMAIL": "synthetic@example.test", "FAKE_DOB": "1990-01-01",
        "FAKE_PHONE": "07700900123", "FAKE_POSTCODE": "SW1A 1AA", "SIGNUP_PASSWORD": "synthetic",
    ])
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-portal-" + UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func run(_ oracle: PortalOracle, url: String = "https://portal.example/entry") async
        -> PortalAttempt
    {
        await PortalWorkflow(client: oracle, resources: resources, dataDirectory: root).login(
            url: URL(string: url)!, identity: identity,
            network: NetworkSnapshot(
                interface: "en0", gatewayIP: "192.168.1.1", gatewayMAC: "02:00:00:00:00:01",
                wifiInterfaces: ["en0"]))
    }
    func testPublicPortalCannotSubmitPersonaToPrivateLAN() async {
        let oracle = PortalOracle(.lanPivot)
        _ = await run(oracle)
        let posts = await oracle.submittedRequests()
        XCTAssertTrue(posts.isEmpty, "Private network pivot must be denied before submission")
    }
    func testPublicCrossOriginGuestRegistrationRetainsStaticSupport() async {
        let oracle = PortalOracle(.publicCrossOrigin)
        let outcome = await run(oracle)
        XCTAssertEqual(outcome.outcome, .submitted)
        let posts = await oracle.submittedRequests()
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url.host, "registration.example")
    }
    func testPortalCanSubmitToItsOwnPrivateGateway() async {
        let oracle = PortalOracle(.ownGateway)
        let outcome = await run(oracle, url: "http://192.168.1.1/entry")
        XCTAssertEqual(outcome.outcome, .submitted)
        let posts = await oracle.submittedRequests()
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts.first?.url.host, "192.168.1.1")
    }
    func testOTPRevealedByCorrectionStopsBeforeSecondSubmission() async {
        let oracle = PortalOracle(.otpAfterCorrection)
        let outcome = await run(oracle)
        XCTAssertEqual(outcome.outcome, .unsupported)
        let posts = await oracle.submittedRequests()
        XCTAssertEqual(
            posts.count, 1, "An OTP introduced after phone rejection must stop the correction loop")
    }
    func testJSONSuccessFalseIsRejectedEvenWithoutFieldErrors() async {
        let oracle = PortalOracle(.explicitRejection)
        let outcome = await run(oracle)
        XCTAssertNotEqual(
            outcome.outcome, .submitted,
            "Explicit server rejection must not be a candidate automatic success")
        let posts = await oracle.submittedRequests()
        XCTAssertEqual(posts.count, 1)
    }
    func testSixDistinctStaticStagesKeepFreshTokens() async {
        let oracle = PortalOracle(.sixSteps)
        let outcome = await run(oracle)
        XCTAssertEqual(outcome.outcome, .submitted)
        let posts = await oracle.submittedRequests()
        XCTAssertEqual(posts.count, 6)
        for (index, post) in posts.enumerated() {
            XCTAssertEqual(post.url.path, "/step\(index+1)")
            XCTAssertTrue(
                String(decoding: post.body ?? Data(), as: UTF8.self).contains(
                    "csrf=token-\(index+1)"))
        }
    }
    func testConnectSubmitIsChosenOverEarlierBackButton() async {
        let oracle = PortalOracle(.positiveSubmit)
        _ = await run(oracle)
        let posts = await oracle.submittedRequests()
        let body = String(decoding: posts.first?.body ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("connect=1"))
        XCTAssertFalse(body.contains("back=1"))
    }
    func testNandosTrustedGrantGETCountsAsAcceptedActionWithoutPersonaDisclosure() async {
        let oracle = ProviderGrantOracle()
        let entry = URL(
            string:
                "https://free-wifi.nandos.co.uk/?base_grant_url=https%3A%2F%2Fnode.network-auth.com%2Fgrant&user_continue_url=https%3A%2F%2Ffree-wifi.nandos.co.uk%2Fconnected&node_mac=02%3A00%3A00%3A00%3A00%3A01"
        )!
        let result = await PortalWorkflow(client: oracle, resources: resources, dataDirectory: root)
            .login(url: entry, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.actions, 1)
        let requests = await oracle.observed()
        XCTAssertEqual(requests.count, 2)
        let grant = requests.last!
        XCTAssertEqual(grant.method, "GET")
        XCTAssertEqual(grant.url.host, "node.network-auth.com")
        XCTAssertNil(grant.body)
        XCTAssertFalse(grant.url.absoluteString.contains("synthetic"))
        let query = URLComponents(url: grant.url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.map(\.name), ["continue_url"])
        XCTAssertTrue(
            query?.first?.value?.hasPrefix("https://free-wifi.nandos.co.uk/connected/") == true)
    }
    func testNandosLookalikeGrantHostStopsBeforeOutboundGrant() async {
        let oracle = ProviderGrantOracle()
        let entry = URL(
            string:
                "https://free-wifi.nandos.co.uk/?base_grant_url=https%3A%2F%2Fnetwork-auth.com.attacker.example%2Fgrant&user_continue_url=https%3A%2F%2Ffree-wifi.nandos.co.uk%2Fconnected"
        )!
        let result = await PortalWorkflow(client: oracle, resources: resources, dataDirectory: root)
            .login(url: entry, identity: identity, network: NetworkSnapshot())
        XCTAssertNotEqual(result.outcome, .submitted)
        XCTAssertEqual(result.actions, 0)
        let requests = await oracle.observed()
        XCTAssertEqual(requests.count, 1)
    }
}

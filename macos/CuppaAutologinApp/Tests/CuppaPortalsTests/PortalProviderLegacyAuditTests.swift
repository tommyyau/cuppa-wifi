import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalProviderLegacyAuditTests: XCTestCase {
    let h = PortalWorkflowTests()
    let ws = WirelessSocialParityTests()
    var btHTML: String {
        "<form action='/access/auth' method='post'><input name='form_type' type='hidden' value='RegistrationForm'><input name='email' type='email'><input name='accept_terms' type='checkbox' value='1'></form>"
    }
    func testBTUnchangedAndExplicitJSONRejectionNeverRepost() async {
        for response in [btHTML, "{\"success\":false,\"errors\":{\"email\":\"Invalid\"}}"] {
            let client = MockHTTP([
                h.response(btHTML, "https://portal.btwifi.com/access/"),
                h.response(response, "https://portal.btwifi.com/access/auth"),
            ])
            let result = await h.workflow(client).login(
                url: URL(string: "https://portal.btwifi.com/access/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "bt_wifi_registration_rejected")
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 2)
        }
    }
    func testBTLoopbackJSONRedirectHasProviderReasonAndNoRequest() async {
        let client = MockHTTP([
            h.response(btHTML, "https://portal.btwifi.com/access/"),
            h.response(
                "{\"success\":true,\"url\":\"http://127.0.0.1/private\"}",
                "https://portal.btwifi.com/access/auth"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://portal.btwifi.com/access/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "bt_wifi_untrusted_grant_redirect")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 2)
    }
    func testGenericLiteralRedirectTransfersBTLegacyProtocol() async throws {
        let data = try Data(
            contentsOf: h.fixtures.appendingPathComponent("venue_contracts.json"))
        let document = try XCTUnwrap(object(String(decoding: data, as: UTF8.self)))
        let contract = try XCTUnwrap(
            (document["contracts"] as? [[String: Any]])?.first {
                $0["id"] as? String == "picturehouse"
            })
        let specs = try XCTUnwrap(contract["responses"] as? [[String: Any]])
        let client = MockHTTP(
            [
                h.response(
                    "<script>window.location='https://www.btwifi.com:8443/home';</script>",
                    "http://captive.apple.com/")
            ] + specs.map { h.response($0["body"] as? String ?? "", $0["url"] as? String ?? "") })
        let result = await h.workflow(client).login(
            url: URL(string: "http://captive.apple.com/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        XCTAssertEqual(result.venue, "Picturehouse")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].url.absoluteString, "https://reg.btwifi.com/registration/check")
        XCTAssertEqual(h.fields(requests[3])["detail_email"], h.identity.email)
        XCTAssertEqual(h.fields(requests[3])["btMarketingConsent"], "false")
        XCTAssertNil(h.fields(requests[3])["partnerMarketingConsent"])
        XCTAssertFalse(requests.contains { $0.url.host == "picturehouses.com" })
    }
    func testNandosStrictLandingAndNetworkAuthHostnameBoundary() async {
        let parameters =
            "?base_grant_url=https%3A%2F%2Feu.network-auth.com%2Fsplash%2Fgrant&user_continue_url=https%3A%2F%2Fexample.org%2F&node_mac=aa%3Abb%3Acc%3Add%3Aee%3Aff"
        for host in ["evil.example", "free-wifi.nandos.co.uk.evil.example"] {
            let url = "https://\(host)/" + parameters
            let client = MockHTTP([
                h.response(
                    "<script>window.portalData={user_continue_url:'http://captive.apple.com/'};</script>",
                    url)
            ])
            let result = await h.workflow(client).login(
                url: URL(string: url)!, identity: h.identity, network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, .browser)
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1)
        }
        for grant in [
            "https://evil.example/collect", "https://eu.network-auth.com.evil.example/splash/grant",
            "http://eu.network-auth.com/splash/grant",
        ] {
            var url = URLComponents(string: "https://free-wifi.nandos.co.uk/")!
            url.queryItems = [
                .init(name: "base_grant_url", value: grant),
                .init(name: "user_continue_url", value: "https://example.org/"),
            ]
            let client = MockHTTP([h.response("Nando's", url.url!.absoluteString)])
            let result = await h.workflow(client).login(
                url: url.url!, identity: h.identity, network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "nandos_invalid_grant_parameters")
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1)
        }
        let url = URL(string: "https://free-wifi.nandos.co.uk/" + parameters)!
        let client = MockHTTP([
            h.response(
                "<script>window.portalData={user_continue_url:'http://captive.apple.com/'};</script>",
                url.absoluteString), h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: url, identity: h.identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        let query = URLComponents(url: requests[1].url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(
            query?.first { $0.name == "continue_url" }?.value,
            "https://free-wifi.nandos.co.uk/connected/aa%3Abb%3Acc%3Add%3Aee%3Aff")
    }
    func testWirelessAllPhoneAliasesAndMetadataUseConfiguredContact() async {
        for field in [
            ["name": "mobilenumber"], ["name": "mobile_number"], ["name": "mobile-number"],
            ["name": "Mobile Number"],
            ["name": "custom_42", "type": "phone", "label": "Mobile telephone"],
        ] {
            let required = [
                field.merging(["requirement": "required"], uniquingKeysWith: { _, last in last })
            ]
            let client = MockHTTP([
                ws.landing(fields: required), ws.auth(fields: required), ws.accepted, ws.accepted,
                ws.accepted, ws.accepted,
            ])
            let result = await ws.run(client)
            XCTAssertEqual(result.outcome, .submitted, result.reason)
            let requests = await client.sent()
            XCTAssertEqual(h.fields(requests[2])[field["name"]!], "+447700900123")
        }
    }
    func testWirelessPhoneExhaustionLeavesAvailableSuccessUnusedAndLearns() async throws {
        let fields = [["name": "mobilenumber", "type": "phone", "requirement": "required"]]
        let rejected = h.response(
            "{\"success\":false,\"validationFieldErrors\":[{\"fieldName\":\"mobilenumber\",\"errors\":[\"Invalid\"]}]}",
            ws.url)
        let client = MockHTTP([
            ws.landing(fields: fields), ws.auth(fields: fields), rejected, rejected, rejected,
            ws.accepted,
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"phone_validating_venues\":[\"old-venue\"],\"prefer_real_phone\":true}".utf8)
            .write(to: directory.appendingPathComponent("phone_policy.json"))
        let workflow = PortalWorkflow(
            client: client, resources: h.resources, dataDirectory: directory)
        let result = await workflow.login(
            url: URL(string: ws.url)!, identity: h.identity,
            network: NetworkSnapshot(gatewayMAC: "aa:bb:cc:dd:ee:ff"))
        XCTAssertEqual(result.reason, "persona_phone_rejected")
        let requests = await client.sent()
        XCTAssertEqual(
            requests.dropFirst(2).compactMap { h.fields($0)["mobilenumber"] },
            ["+447700900123", "07700900123", "00447700900123"])
        XCTAssertEqual(requests.count, 5)
        let learned = try XCTUnwrap(
            object(
                String(
                    contentsOf: directory.appendingPathComponent("phone_policy.json"),
                    encoding: .utf8)))
        XCTAssertTrue(
            (learned["phone_validating_venues"] as? [String] ?? []).contains("aa:bb:cc:dd:ee:ff"))
    }
    func testWirelessVenueFallbackAndReservedEmailSerialization() async {
        let journey =
            "window.journeyData={\"journeyMetaData\":{\"journey_activity_data\":{}},\"journeyLogic\":{\"sequence\":{}},\"stdFields\":[],\"venue\":{\"name\":\"Wingstop - Example Branch\"}};"
        for email in ["sarah.chen@example.com", "not-an-email"] {
            var person = h.identity
            person.values["FAKE_EMAIL"] = email
            let client = MockHTTP([h.response("<script>\(journey)</script>", ws.url)])
            let result = await h.workflow(client).login(
                url: URL(string: ws.url)!, identity: person, network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "privacy_email_required")
            XCTAssertEqual(result.venue, "Wingstop - Example Branch")
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1)
        }
        var person = h.identity
        person.values["FAKE_PHONE"] = "+44 7700 900 123"
        let fields = [["name": "mobilenumber", "requirement": "required"]]
        let client = MockHTTP([
            ws.landing(fields: fields), ws.auth(fields: fields), ws.accepted, ws.accepted,
            ws.accepted, ws.accepted,
        ])
        let result = await h.workflow(client).login(
            url: URL(string: ws.url)!, identity: person, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(h.fields(requests[2])["mobilenumber"], "+447700900123")
    }
}

extension PortalProviderLegacyAuditTests {
    func testBTSantanderObservedDropdownValuesAndAjaxShape() async {
        let html =
            "<h1>Santander</h1><form action='/access/auth' method='post'><input name='form_type' type='hidden' value='RegistrationForm'><input type='email' name='email' required><label>Are you a Santander Customer?<select name='custom_1681' required><option value=''>Choose</option><option value='yes'>Yes</option><option value='no'>No</option></select></label><label>Why are you visiting us today?<select name='custom_1682' required><option value=''>Choose</option><option value='account'>Managing my account</option><option value='cowork'>Co-working</option></select></label><input name='accept_terms' type='checkbox' value='1'><input name='santander_marketing' type='checkbox' value='1'></form>"
        let client = MockHTTP([
            h.response(html, "https://portal.btwifi.com/access/"),
            h.response(
                "{\"success\":true,\"url\":\"/access/connected\"}",
                "https://portal.btwifi.com/access/auth"),
            h.response("Connected", "https://portal.btwifi.com/access/connected"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://portal.btwifi.com/access/")!, identity: h.identity,
            network: NetworkSnapshot(ssid: "Tim Hortons"))
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        XCTAssertEqual(result.venue, "Santander")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 3)
        guard requests.count == 3 else { return }
        XCTAssertEqual(requests[1].method, "POST")
        XCTAssertEqual(requests[1].headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertEqual(requests[1].url.query, "marketing=0")
        XCTAssertEqual(h.fields(requests[1])["custom_1681"], "no")
        XCTAssertEqual(h.fields(requests[1])["custom_1682"], "cowork")
        XCTAssertEqual(h.fields(requests[1])["accept_terms"], "1")
        XCTAssertNil(h.fields(requests[1])["santander_marketing"])
    }
}

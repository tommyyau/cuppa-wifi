import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class WirelessSocialParityTests: XCTestCase {
    let h = PortalWorkflowTests()
    let url = "https://wifi.wireless-social.com/login"
    var user: [String: Any] {
        ["uuid": "synthetic-user", "authMethod": "form", "authMethodIdentifier": h.identity.email]
    }
    func landing(fields: [[String: String]] = [], extras: String = "") -> HTTPResponse {
        let journey: [String: Any] = [
            "stdFields": fields, "venue": ["name": "Test venue", "operatorDataSet": [:]],
            "journeyMetaData": ["journey_activity_data": ["ssid": "Fixture SSID"]],
            "journeyLogic": ["sequence": ["1": ["type": "Page"], "2": ["type": "PostStart"]]],
        ]
        return h.response(
            "<script>window.journeyData=" + jsonText(journey) + ";" + extras + "</script>", url)
    }
    func auth(fields: [[String: String]] = [], stringUser: Bool = false) -> HTTPResponse {
        h.response(
            jsonText([
                "success": true, "wifiUser": stringUser ? jsonText(user) as Any : user,
                "stdFields": fields,
            ]), url)
    }
    var accepted: HTTPResponse { h.response(jsonText(["success": true, "wifiUser": user]), url) }
    func run(_ client: MockHTTP) async -> PortalAttempt {
        await h.workflow(client).login(
            url: URL(string: url)!, identity: h.identity, network: NetworkSnapshot())
    }
    func testNewUserAliasesRequiredOnlyAndMarketingDeclined() async throws {
        let required = [
            ["name": "mobile_number", "requirement": "required"],
            ["name": "fname", "requirement": "required"],
            ["name": "opaque_email", "type": "email", "requirement": "required"],
            ["name": "postcode", "requirement": "optional"],
        ]
        let client = MockHTTP([
            landing(fields: required), auth(fields: required, stringUser: true), accepted, accepted,
            accepted, accepted,
        ])
        let result = await run(client)
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        XCTAssertEqual(result.venue, "Fixture SSID")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 6)
        let profile = h.fields(requests[2])
        XCTAssertEqual(profile["mobile_number"], "+447700900123")
        XCTAssertEqual(profile["fname"], "Alex")
        XCTAssertEqual(profile["opaque_email"], h.identity.email)
        XCTAssertNil(profile["postcode"])
        let dataset = h.fields(requests[3])
        XCTAssertEqual(dataset["cdt[op]"], "1")
        XCTAssertFalse(dataset.keys.contains { $0.hasPrefix("consent[") })
        let progressString = try XCTUnwrap(h.fields(requests[4])["ws_journey_login_progress"])
        let progress = try XCTUnwrap(object(progressString))
        let nodes = try XCTUnwrap(progress["journey"] as? [[String: String]])
        XCTAssertTrue(nodes.contains { $0["type"] == "PostStart" })
    }
    func testProfileListValidationCorrectsPhoneOnly() async {
        let required = [
            ["name": "mobile_number", "requirement": "required"],
            ["name": "fname", "requirement": "required"],
        ]
        let rejection = h.response(
            jsonText([
                "success": false,
                "validationFieldErrors": [
                    ["fieldName": "mobile_number", "errors": ["invalid format"]]
                ],
            ]), url)
        let client = MockHTTP([
            landing(fields: required), auth(fields: required), rejection, accepted, accepted,
            accepted, accepted,
        ])
        let result = await run(client)
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        let requests = await client.sent()
        XCTAssertEqual(h.fields(requests[2])["mobile_number"], "+447700900123")
        XCTAssertEqual(h.fields(requests[3])["mobile_number"], "07700900123")
        XCTAssertEqual(h.fields(requests[2])["fname"], h.fields(requests[3])["fname"])
        XCTAssertEqual(result.corrections["mobile_number"], ["+447700900123", "07700900123"])
    }
    func testRejectedPhoneExhaustionNeverInventsDigits() async {
        let required = [["name": "phone", "requirement": "required"]]
        let rejection = h.response(
            jsonText(["success": false, "validationFieldErrors": ["phone": ["invalid"]]]), url)
        let client = MockHTTP([
            landing(fields: required), auth(fields: required), rejection, rejection, rejection,
            rejection,
        ])
        let result = await run(client)
        XCTAssertEqual(result.reason, "persona_phone_rejected")
        let requests = await client.sent()
        let numbers = requests.dropFirst(2).compactMap { h.fields($0)["phone"] }
        XCTAssertTrue(
            numbers.allSatisfy { ["+447700900123", "07700900123", "00447700900123"].contains($0) })
        XCTAssertLessThanOrEqual(numbers.count, 4)
    }
    func testUnknownMetadataRequiredFieldFailsClosed() async {
        for name in ["mystery", "passport_number"] {
            let required = [["name": name, "requirement": "required"]]
            let client = MockHTTP([landing(fields: required), auth(fields: required)])
            let result = await run(client)
            XCTAssertEqual(result.reason, "unknown_required_field")
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 2)
        }
    }
    func testAuthEmailValidationRequiresPrivateRelay() async {
        let client = MockHTTP([
            landing(),
            h.response(
                jsonText(["success": false, "validationFieldErrors": ["email": ["invalid"]]]), url),
        ])
        let result = await run(client)
        XCTAssertEqual(result.reason, "privacy_email_required")
    }
    func testExplicitPostauthRejectionStopsBeforeEnd() async {
        let client = MockHTTP([landing(), auth(), h.response("{\"success\":false}", url)])
        let result = await run(client)
        XCTAssertEqual(result.reason, "wireless_social_postauth_rejected")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 3)
    }
    func testRelativeMerakiGrantAndHiddenOpaqueCredentials() async {
        let grantURL = "https://eu.network-auth.com/splash/opaque/login"
        let wrapper =
            "<form name='extRedirect' action='\(grantURL)' method='post'><input type='hidden' name='username' value='server-user'><input type='hidden' name='password' value='server-token'><input type='hidden' name='continue_url' value='https://example.net/'></form>"
        let client = MockHTTP([
            landing(), auth(),
            h.response(
                "{\"success\":true,\"redirectUrl\":\"/meraki/mr/post-auth/redirect/opaque\"}", url),
            h.response(
                wrapper, "https://wifi.wireless-social.com/meraki/mr/post-auth/redirect/opaque"),
            h.response("Done", grantURL), accepted,
        ])
        let result = await run(client)
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(requests[4].method, "POST")
        XCTAssertEqual(requests[4].url.absoluteString, grantURL)
        XCTAssertEqual(h.fields(requests[4])["password"], "server-token")
    }
    func testUntrustedCrossOriginGrantNeverFetched() async {
        let client = MockHTTP([
            landing(), auth(),
            h.response(
                "{\"success\":true,\"redirectUrl\":\"https://evil.example/meraki/mr/post-auth/redirect/opaque\"}",
                url),
        ])
        let result = await run(client)
        XCTAssertEqual(result.reason, "wireless_social_untrusted_grant_redirect")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 3)
    }
    func testUntrustedExternalGrantFormNeverPosted() async {
        let wrapper =
            "<form name='extRedirect' action='https://evil.example/splash/opaque/login' method='post'><input type='hidden' name='username' value='server-user'><input type='hidden' name='password' value='server-token'></form>"
        let client = MockHTTP([
            landing(), auth(),
            h.response(
                "{\"success\":true,\"redirectUrl\":\"/meraki/mr/post-auth/redirect/opaque\"}", url),
            h.response(wrapper, url),
        ])
        let result = await run(client)
        XCTAssertEqual(result.reason, "wireless_social_untrusted_grant_form")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 4)
    }
    func testConfiguredCrossOriginEndpointNeverReceivesPersona() async {
        let client = MockHTTP([landing(extras: "window.wsAuthFormUrl='https://evil.example/auth';")]
        )
        let result = await run(client)
        XCTAssertTrue(result.reason.hasPrefix("wireless_social_untrusted"))
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
    }
    func testJourneyDecoderIgnoresBracesInsideJSONString() {
        XCTAssertEqual(
            extractJourney("window.journeyData={\"name\":\"{brace} \\\"quoted\\\"\"};other();")?[
                "name"] as? String, "{brace} \"quoted\"")
        XCTAssertNil(extractJourney("window.journeyData=notJSON;"))
    }
}

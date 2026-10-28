import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

actor MockHTTP: HTTPClient {
    var queue: [HTTPResponse]
    var requests: [HTTPRequest] = []
    init(_ queue: [HTTPResponse]) { self.queue = queue }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return queue.removeFirst()
    }
    func sent() -> [HTTPRequest] { requests }
}
@MainActor
final class PortalWorkflowTests: XCTestCase {
    var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    var resources: URL { root.appendingPathComponent("macos/Resources") }
    var fixtures: URL { root.appendingPathComponent("macos/TestFixtures/Portal") }
    var identity: PortalIdentity {
        PortalIdentity(values: [
            "FAKE_FIRST_NAME": "Alex", "FAKE_LAST_NAME": "Morgan",
            // Reserved subdomain: exercises success while apex-example rejection stays covered.
            "FAKE_EMAIL": "fixture@guest.example.net", "FAKE_PHONE": "07700900123",
            "FAKE_DOB": "1988-03-14", "FAKE_POSTCODE": "SW1A 1AA", "SIGNUP_PASSWORD": "secret",
            "FAKE_COUNTRY": "United Kingdom",
        ])
    }
    func response(
        _ html: String, _ url: String = "https://guest.example.net/", status: Int = 200,
        headers: [String: String] = [:]
    ) -> HTTPResponse {
        HTTPResponse(
            url: URL(string: url)!, status: status, headers: headers, body: Data(html.utf8))
    }
    func workflow(_ client: MockHTTP) -> PortalWorkflow {
        PortalWorkflow(
            client: client, resources: resources,
            dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString))
    }
    func fields(_ request: HTTPRequest) -> [String: String] {
        let text = String(data: request.body ?? Data(), encoding: .utf8) ?? ""
        return Dictionary(
            (URLComponents(string: "https://x.invalid/?" + text)?.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }, uniquingKeysWith: { _, last in last })
    }
    func testFixtureIdentityHiddenAndConsent() async throws {
        let html = try String(
            contentsOf: fixtures.appendingPathComponent("uk_guest_portal.html"),
            encoding: .utf8)
        let client = MockHTTP([
            response(html),
            response("<h1>Connected</h1>", "https://guest.example.net/guest/connect"),
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertTrue(result.pendingSubmission)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 2)
        let data = fields(requests[1])
        XCTAssertEqual(data["token"], "abc123token")
        XCTAssertEqual(data["mac"], "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(data["email"], identity.email)
        XCTAssertEqual(data["terms_accepted"], "yes")
        XCTAssertNil(data["marketing_opt_in"])
    }
    func testAirportJavaScriptHandoffBeforePost() async throws {
        let html = try String(
            contentsOf: fixtures.appendingPathComponent("airport_js_portal.html"),
            encoding: .utf8)
        let client = MockHTTP([response(html, "https://secure.boingohotspot.net/")])
        let result = await workflow(client).login(
            url: URL(string: "https://secure.boingohotspot.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertEqual(result.reason, "javascript_form_requires_browser")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
    }
    func testDataEndpointGenericHandoff() async {
        let client = MockHTTP([
            response(
                "<form data-endpoint='join' method='post'><input type='email' name='email'></form>")
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertFalse(result.pendingSubmission)
    }
    func testRequiredMarketingFailsWithoutSubmission() async {
        let client = MockHTTP([
            response(
                "<form><input type='checkbox' name='marketing' required><button>Connect</button></form>"
            )
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "marketing_consent_required")
        XCTAssertEqual(result.outcome, .unsupported)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
    }
    func testCurrentPasswordNotSignupPassword() async {
        let client = MockHTTP([
            response(
                "<form method='post'><input type='password' name='password' autocomplete='current-password' required></form>"
            )
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "account_credentials_required")
        XCTAssertFalse(result.pendingSubmission)
    }
    func testIssuedCustomerIdentifierStops() async {
        let client = MockHTTP([
            response(
                "<form><label>Customer number<input name='customer_number' required></label><input name='email' type='email'></form>"
            )
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "unknown_required_field")
    }
    func testUnknownRequiredStopsWithoutInventingIdentity() async {
        let client = MockHTTP([response("<form><input name='mystery' required></form>")])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "requires_browser")
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertFalse(result.pendingSubmission)
    }
    func testOTPBoundary() async {
        let client = MockHTTP([
            response("<form><input name='code' autocomplete='one-time-code' required></form>")
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "verification_code_required")
    }
    func testUnchangedFormHandsOffWithSchemaSignature() async {
        let html =
            "<form method='post'><input name='token' type='hidden' value='fresh'><input name='email' type='email'></form>"
        let client = MockHTTP([
            response(html), response(html.replacingOccurrences(of: "fresh", with: "rotated")),
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "repeated_form_requires_browser")
        XCTAssertEqual(result.actions, 1)
        XCTAssertNotNil(result.signature)
        XCTAssertTrue(result.pendingSubmission)
    }
    func testPostcodeCorrectionUsesSameIdentityOnly() async {
        let html = "<form method='post'><input name='postcode' required></form>"
        let client = MockHTTP([
            response(html), response("{\"validationFieldErrors\":{\"postcode\":[\"invalid\"]}}"),
            response("<h1>Done</h1>"),
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(fields(requests[1])["postcode"], "SW1A 1AA")
        XCTAssertEqual(fields(requests[2])["postcode"], "SW1A1AA")
        XCTAssertEqual(result.corrections["postcode"], ["SW1A 1AA", "SW1A1AA"])
    }
    func testPublicCrossOriginGuestSubmission() async {
        let client = MockHTTP([
            response(
                "<form action='https://foreign.example.net/collect' method='post'><input name='email' type='email'></form>"
            ), response("Done", "https://foreign.example.net/collect"),
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertTrue(result.pendingSubmission)
    }
    func testRedirect307DoesNotForwardPersonaAcrossOrigin() async {
        let client = MockHTTP([
            response("<form method='post'><input name='email' type='email'></form>"),
            response("", status: 307, headers: ["Location": "https://foreign.example.net/"]),
        ])
        let result = await workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "cross_origin_submission_redirect")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 2)
    }
    func testLoopbackNavigationRejected() async {
        let client = MockHTTP([
            response("<a href='http://127.0.0.1:8080'>Connect</a>", "http://guest.example.net/")
        ])
        let result = await workflow(client).login(
            url: URL(string: "http://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "unsafe_portal_destination")
    }
    func testBTActualAjaxContractAndDeclinedMarketing() async {
        let url = "https://portal.btwifi.com/"
        let html =
            "<form action='/register' method='post'><input type='hidden' name='form_type' value='registrationform'><input type='hidden' name='csrf' value='real-token'><input type='email' name='email'></form>"
        let client = MockHTTP([
            response(html, url), response("{\"success\":true,\"url\":\"/grant\"}", url),
            response("done", "https://portal.btwifi.com/grant"),
        ])
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.provider, "bt")
        let requests = await client.sent()
        XCTAssertEqual(requests[1].headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertTrue(requests[1].url.query?.contains("marketing=0") == true)
        XCTAssertEqual(fields(requests[1])["csrf"], "real-token")
    }
    func testBTUntrustedGrantNotFetchedButSubmissionVerifiedByEngine() async {
        let url = "https://portal.btwifi.com/"
        let html =
            "<form method='post'><input type='hidden' name='form_type' value='registrationform'><input type='email' name='email'></form>"
        let client = MockHTTP([
            response(html, url),
            response("{\"success\":true,\"url\":\"https://tracking.example.net/\"}", url),
        ])
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 2)
    }
    func testFydeliaRetainsUnifiQueryAndNationalPhone() async {
        let url = "https://splash.fydelia.com/splash?id=client&ap=ap&url=https%3A%2F%2Fexample.net"
        let html =
            "<script>fod_2_step_marketing_js=true;marketing_invoke_moment='form_submission';</script><form method='post'><input type='hidden' name='loginMethod' value='email'><input name='userEmail' type='email'><select name='phone_number_prefix'><option value='44' selected>+44</option></select><input type='tel' name='phone_number'><input type='checkbox' name='subscribe_sms'></form>"
        let client = MockHTTP([
            response(html, "https://splash.fydelia.com/splash"),
            response("done", "https://splash.fydelia.com/splash"),
            response("continued", "https://example.net"),
        ])
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertTrue(requests[1].url.query?.contains("id=client") == true)
        XCTAssertEqual(fields(requests[1])["phone_number"], "7700900123")
        XCTAssertEqual(fields(requests[1])["2_step_marketing_chosen"], "true")
        XCTAssertNil(fields(requests[1])["subscribe_sms"])
    }
    func testNandosValidatedMerakiGrant() async {
        let url =
            "https://free-wifi.nandos.co.uk/?base_grant_url=https%3A%2F%2Feu.network-auth.com%2Fsplash%2Fgrant&user_continue_url=https%3A%2F%2Fexample.net&node_mac=aa%3Abb%3Acc%3Add%3Aee%3Aff"
        let client = MockHTTP([
            response("Next.js", url), response("Done", "https://eu.network-auth.com/splash/grant"),
        ])
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(requests[1].url.host, "eu.network-auth.com")
        XCTAssertTrue(requests[1].url.query?.contains("continue_url=") == true)
    }
    func testWirelessReturningAccountSkipsRegistrationDatasets() async {
        let url = "https://wifi.wireless-social.com/"
        let html =
            "<script>window.journeyData={\"venue\":{\"name\":\"Venue\",\"operatorDataSet\":{}},\"stdFields\":[]};</script>"
        let client = MockHTTP([
            response(html, url), response("{\"success\":true,\"wifiUser\":{\"uuid\":\"u\"}}", url),
            response("{\"success\":true}", url), response("{\"success\":true}", url),
        ])
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.venue, "Venue")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[1].url.path, "/journey/auth/user/form")
        XCTAssertEqual(requests[2].url.path, "/cambium/cn-pilot/journey/post-auth/process")
        XCTAssertEqual(requests[3].url.path, "/journey/end/process")
    }
    func testWirelessReservedEmailRequiresPrivateRelay() async {
        let url = "https://wifi.wireless-social.com/"
        let client = MockHTTP([response("<script>window.journeyData={};</script>", url)])
        var person = identity
        person.values["FAKE_EMAIL"] = "alex@example.com"
        let result = await workflow(client).login(
            url: URL(string: url)!, identity: person, network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "privacy_email_required")
    }
    func testFieldContextAndNativeTypePrecedence() {
        let rules = PortalRules(resources: resources)
        let page = HTMLPage(
            "<form><fieldset><legend>Date of birth</legend><label for='d'>Day</label><select name='part' id='d'><option value='14'>14</option></select></fieldset><span id='hint'>Email address</span><input name='x' aria-describedby='hint'><input type='email' name='phone'></form>"
        )
        XCTAssertEqual(rules.intent(page.forms[0].fields[0].descriptor), "birth_day")
        XCTAssertEqual(rules.intent(page.forms[0].fields[1].descriptor), "email")
        XCTAssertEqual(rules.intent(page.forms[0].fields[2].descriptor), "email")
    }
}

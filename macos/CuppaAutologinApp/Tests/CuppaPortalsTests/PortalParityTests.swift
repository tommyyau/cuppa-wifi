import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalParityTests: XCTestCase {
    let helpers = PortalWorkflowTests()
    var resources: URL { helpers.resources }
    var fixtures: URL { helpers.fixtures }
    var identity: PortalIdentity { helpers.identity }
    var rules: PortalRules { PortalRules(resources: resources) }
    func form(_ fields: String) throws -> HTMLForm {
        try XCTUnwrap(HTMLPage("<form method='post'>" + fields + "</form>").forms.first)
    }
    func filled(_ html: String, person: PortalIdentity? = nil) throws -> [String: String] {
        Dictionary(
            try fill(form(html), identity: person ?? identity, rules: rules),
            uniquingKeysWith: { _, last in last })
    }
    func testCompleteSharedDescriptorCorpus() throws {
        let data = try Data(
            contentsOf: fixtures.appendingPathComponent("field_descriptors.json"))
        let cases = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        for fixture in cases {
            let descriptor = try XCTUnwrap(fixture["descriptor"] as? [String: String])
            XCTAssertEqual(
                rules.intent(descriptor), fixture["intent"] as? String, "descriptor: \(descriptor)")
        }
    }
    func testFiveHistoricalVenueRequestContracts() async throws {
        let data = try Data(
            contentsOf: fixtures.appendingPathComponent("venue_contracts.json"))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        for contract in try XCTUnwrap(document["contracts"] as? [[String: Any]]) {
            let name = contract["id"] as? String ?? ""
            let entry = try XCTUnwrap(contract["entry_url"] as? String)
            let specs = try XCTUnwrap(contract["responses"] as? [[String: Any]])
            let queue = specs.map { spec in
                helpers.response(
                    spec["body"] as? String ?? "", spec["url"] as? String ?? entry,
                    status: spec["status"] as? Int ?? 200)
            }
            let client = MockHTTP(queue)
            let result = await helpers.workflow(client).login(
                url: URL(string: entry)!, identity: identity,
                network: NetworkSnapshot(ssid: contract["ssid"] as? String))
            XCTAssertEqual(result.outcome, .submitted, "\(name): \(result.reason)")
            let requests = await client.sent()
            for expected in try XCTUnwrap(contract["expected_requests"] as? [[String: Any]]) {
                let index = try XCTUnwrap(expected["index"] as? Int)
                guard index < requests.count else {
                    XCTFail("\(name) missing request \(index)")
                    continue
                }
                let request = requests[index]
                XCTAssertEqual(request.method, expected["method"] as? String, name)
                if let url = expected["url"] as? String {
                    XCTAssertEqual(request.url.absoluteString, url, name)
                }
                if let prefix = expected["url_prefix"] as? String {
                    XCTAssertTrue(request.url.absoluteString.hasPrefix(prefix), name)
                }
                let fields = helpers.fields(request)
                let tokens = [
                    "$first_name": identity.firstName, "$last_name": identity.lastName,
                    "$email": identity.email,
                ]
                for (key, value) in expected["fields"] as? [String: String] ?? [:] {
                    XCTAssertEqual(fields[key], tokens[value] ?? value, "\(name):\(key)")
                }
                for absent in expected["absent"] as? [String] ?? [] {
                    XCTAssertNil(fields[absent], "\(name):\(absent)")
                }
            }
        }
    }
    func testLinkedDescriptionsDOBActualOptionValues() throws {
        var person = identity
        person.values["FAKE_DOB"] = "1988-04-17"
        let html =
            "<p id='hint'>Family name and given name together</p><form><input name='a' aria-describedby='hint' required><fieldset><legend>Date of birth</legend><label for='day'>Day</label><select id='day' name='day' required><option value=''>Choose</option><option value='day-z'>17</option></select><label for='month'>Month</label><select id='month' name='month' required><option value=''>Choose</option><option value='3'>April</option></select><label for='year'>Year</label><select id='year' name='year' required><option value=''>Choose</option><option value='year-z'>1988</option></select></fieldset></form>"
        let parsed = try XCTUnwrap(HTMLPage(html).forms.first)
        let fields = Dictionary(
            try fill(parsed, identity: person, rules: rules), uniquingKeysWith: { _, last in last })
        XCTAssertEqual(
            fields, ["a": identity.fullName, "day": "day-z", "month": "3", "year": "year-z"])
    }
    func testSplitPhoneObservedDialValueAndPattern() throws {
        let fields = try filled(
            "<label for='dial'>Calling code</label><select id='dial' name='dial'><option value='gb'>UK (+44)</option></select><input name='phone' type='tel' pattern='[0-9]{10}' required>"
        )
        XCTAssertEqual(fields, ["dial": "gb", "phone": "7700900123"])
    }
    func testPositiveSubmitWinsOverBackAndMarketingAcceptance() throws {
        let fields = try filled(
            "<button type='submit' name='back' value='1'>Back</button><button type='submit' name='marketing' value='yes'>Accept marketing</button><button type='submit' name='connect' value='go'>Connect</button>"
        )
        XCTAssertEqual(fields, ["connect": "go"])
    }
    func testMarketingRadioDeclinesCheckedOptIn() throws {
        let fields = try filled(
            "<label>Marketing offers<input type='radio' name='offers' value='yes' checked></label><label>No thanks<input type='radio' name='offers' value='no'></label>"
        )
        XCTAssertEqual(fields, ["offers": "no"])
    }
    func testOptOutCheckboxAndTermsWithoutOptIn() throws {
        let fields = try filled(
            "<label>Do not send marketing<input type='checkbox' name='marketing_opt_out' value='no' required></label><input type='checkbox' name='tnc' value='yes' required><input type='checkbox' name='tnc_marketing' checked>"
        )
        XCTAssertEqual(fields, ["marketing_opt_out": "no", "tnc": "yes"])
    }
    func testReadonlyAndDisabledFieldsets() throws {
        let fields = try filled(
            "<input type='email' name='email' value='server@example.net' readonly><fieldset disabled><input type='hidden' name='token' value='must-not-send'><input name='first_name'></fieldset><input name='last_name' disabled>"
        )
        XCTAssertEqual(fields, ["email": "server@example.net"])
    }
    func testDefaultPersonaExtendedFieldsAndPrivacyChoices() throws {
        let fields = try filled(
            "<input name='city'><input name='address' autocomplete='address-line1'><select name='country' required><option value=''>Choose</option><option value='GB'>United Kingdom</option></select><select name='gender' required><option value='female'>Female</option><option value='withheld'>Prefer not to say</option></select><label>Mx<input name='title' type='radio' value='mx'></label>"
        )
        XCTAssertEqual(fields["city"], "London")
        XCTAssertEqual(fields["address"], "1 Example Street")
        XCTAssertEqual(fields["country"], "GB")
        XCTAssertEqual(fields["gender"], "withheld")
        XCTAssertEqual(fields["title"], "mx")
    }
    func testDOBRequestedFormatPreservesDate() throws {
        let fields = try filled(
            "<label>Date of birth DD/MM/YYYY<input name='birth' required></label>")
        XCTAssertEqual(fields["birth"], "14/03/1988")
    }
    func testPhoneConstraintsSelectSameDigitsWithoutClipping() throws {
        XCTAssertEqual(
            try filled(
                "<input name='phone' type='tel' maxlength='10' pattern='[0-9]{10}' required>")[
                    "phone"], "7700900123")
        XCTAssertThrowsError(try filled("<input name='phone' type='tel' maxlength='3' required>"))
    }
    func testProviderAliasesAndDomainBoundaries() {
        XCTAssertEqual(
            rules.profile(URL(string: "https://x.boingohotspot.net")!)["id"] as? String, "boingo")
        XCTAssertEqual(
            rules.profile(URL(string: "https://boingohotspot.net.attacker.example")!)["id"]
                as? String, "generic")
        XCTAssertEqual(
            rules.intent(["name": "opaque"], profile: ["fieldAliases": ["opaque": "first_name"]]),
            "first_name")
    }
    func testSchemaStableAcrossTokensButNotActions() throws {
        let a = try form(
            "<input name='token' type='hidden' value='first'><input name='email' type='email'>")
        let b = try form(
            "<input name='token' type='hidden' value='second'><input name='email' type='email'>")
        XCTAssertEqual(a.signature(rules: rules), b.signature(rules: rules))
        XCTAssertNotEqual(
            a.signature(rules: rules),
            try form("<input name='phone' type='tel'>").signature(rules: rules))
    }
    func testSixDistinctStaticStagesWithFreshTokens() async {
        let url = "https://guest.example.net/step0"
        let responses =
            (0..<6).map { n in
                helpers.response(
                    "<form action='/step\(n)' method='post'><input name='csrf' type='hidden' value='token\(n)'><input name='email' type='email'></form>",
                    "https://guest.example.net/step\(n)")
            } + [helpers.response("Done", "https://guest.example.net/done")]
        let client = MockHTTP(responses)
        let result = await helpers.workflow(client).login(
            url: URL(string: url)!, identity: identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.actions, 6)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 7)
        for n in 0..<min(6, requests.count - 1) {
            XCTAssertEqual(helpers.fields(requests[n + 1])["csrf"], "token\(n)")
        }
    }
    func testPhoneCorrectionStopsAtNewOTP() async {
        let client = MockHTTP([
            helpers.response("<form method='post'><input name='phone' type='tel' required></form>"),
            helpers.response(
                "<aside role='alert'>Telephone invalid format</aside><form><input name='phone' type='tel' required><input name='otp' autocomplete='one-time-code' required></form>"
            ),
        ])
        let result = await helpers.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "verification_code_required")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 2)
    }
    func testJSONExplicitRejectionNeverCandidateSuccess() async {
        for body in [
            "{\"success\":false}", "{\"ok\":false}", "{\"error\":\"denied\"}",
            "{\"errors\":{\"general\":\"denied\"}}",
        ] {
            let client = MockHTTP([
                helpers.response("<form method='post'><input name='email' type='email'></form>"),
                helpers.response(body),
            ])
            let result = await helpers.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, .failed, body)
            XCTAssertEqual(result.reason, "portal_submission_rejected", body)
        }
    }
    func testMetaAndLiteralJSNavigationChain() async {
        let client = MockHTTP([
            helpers.response("<meta http-equiv='refresh' content='0;url=/step'>"),
            helpers.response(
                "<script>window.location.href='/join';</script>", "https://guest.example.net/step"),
            helpers.response(
                "<form method='post'><input name='email' type='email'></form>",
                "https://guest.example.net/join"),
            helpers.response("Done", "https://guest.example.net/join"),
        ])
        let result = await helpers.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[2].url.path, "/join")
    }
    func testNavigationPivotsAndSocialRedirectsBlocked() async {
        for destination in [
            "https://192.168.1.1/", "https://10.1.2.3/", "https://169.254.1.1/",
            "https://[fd00::1]/", "http://guest.example.net/", "https://accounts.google.com/login",
            "https://guest.example.net/oauth/google",
        ] {
            let client = MockHTTP([
                helpers.response("", status: 302, headers: ["Location": destination])
            ])
            let result = await helpers.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: identity,
                network: NetworkSnapshot())
            XCTAssertEqual(
                result.outcome == .failed || result.outcome == .unsupported, true, destination)
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1, destination)
        }
    }
    func testDormantChallengeDoesNotBlockOrdinaryForm() async {
        let html =
            "<p>Optional premium access: OTP payment</p><script>window.captchaAvailable=true;</script><form method='post'><input name='email' type='email' required><input name='otp' autocomplete='one-time-code'><input name='credit' autocomplete='cc-number'></form>"
        let client = MockHTTP([helpers.response(html), helpers.response("Done")])
        let result = await helpers.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
    }
    func testUnavailablePageNeverPostsSearchOrFollowsSignup() async {
        let client = MockHTTP([
            helpers.response(
                "<h1>404 Page not found</h1><form><input name='search'></form><a href='/register'>Connect</a>"
            )
        ])
        let result = await helpers.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "portal_page_unavailable")
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
    }
}

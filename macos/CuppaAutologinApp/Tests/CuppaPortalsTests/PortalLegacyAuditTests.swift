import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

actor FailingPortalHTTP: HTTPClient {
    let failure: URLError
    var count = 0
    init(_ code: URLError.Code) { failure = URLError(code) }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        count += 1
        throw failure
    }
}

@MainActor
final class PortalLegacyAuditTests: XCTestCase {
    let h = PortalWorkflowTests()
    var rules: PortalRules { PortalRules(resources: h.resources) }
    func fillFields(_ html: String) throws -> [String: String] {
        let form = try XCTUnwrap(HTMLPage("<form>" + html + "</form>").forms.first)
        return Dictionary(
            try fill(form, identity: h.identity, rules: rules),
            uniquingKeysWith: { _, last in last })
    }
    func testRegistrySSIDFallbackNamesAndPrecedence() {
        let registry = PortalRegistry()
        for ssid in ["TimHortons_Guest", "tim horton", "TIMHORTONS", "Tim Hortons Wifi"] {
            XCTAssertEqual(
                registry.resolve(domain: nil, ssid: ssid, gatewayMAC: nil),
                .init(name: "Tim Hortons", provider: "generic"))
        }
        XCTAssertEqual(
            registry.resolve(domain: nil, ssid: "Pret Free WiFi", gatewayMAC: nil).name,
            "Pret Free WiFi")
        XCTAssertEqual(
            registry.resolve(domain: "portal.wifinity.example", ssid: nil, gatewayMAC: nil).name,
            "portal.wifinity.example")
        XCTAssertEqual(registry.resolve(domain: nil, ssid: nil, gatewayMAC: nil).name, "unknown")
        for host in [
            "portal.btwifi.com", "www.btwifi.com", "reg.btwifi.com", "login.reg.btwifi.com",
        ] {
            XCTAssertEqual(
                registry.resolve(domain: host, ssid: "Tim Hortons", gatewayMAC: nil).provider, "bt")
        }
        XCTAssertEqual(
            registry.resolve(domain: "wifi.wireless-social.com", ssid: "Tenpin", gatewayMAC: nil)
                .provider, "wireless-social")
        XCTAssertEqual(
            registry.resolve(domain: "example001.fydelia.com", ssid: "Black Sheep", gatewayMAC: nil)
                .provider, "fydelia")
        for host in [
            "portal.btwifi.com.evil.example", "evilfydelia.com", "wireless-social.com.evil",
        ] {
            XCTAssertEqual(
                registry.resolve(domain: host, ssid: nil, gatewayMAC: nil).provider, "generic")
        }
        let custom = PortalRegistry(entries: [
            .init(
                name: "DomainVenue", provider: "generic", domainPattern: "example\\.venue$",
                ssidPattern: "decoy"),
            .init(name: "SSIDVenue", provider: "bt", ssidPattern: "decoy"),
            .init(name: "MACVenue", provider: "bt", gatewayMAC: "aa:bb:cc:dd:ee:ff"),
        ])
        XCTAssertEqual(
            custom.resolve(
                domain: "login.example.venue", ssid: "decoy", gatewayMAC: "AA:BB:CC:DD:EE:FF"
            ).name, "DomainVenue")
        XCTAssertEqual(
            custom.resolve(domain: "other.example", ssid: "decoy", gatewayMAC: "AA:BB:CC:DD:EE:FF")
                .name, "DomainVenue")
        XCTAssertEqual(
            custom.resolve(
                domain: "other.example", ssid: "unknown", gatewayMAC: "AA:BB:CC:DD:EE:FF"
            ).name, "MACVenue")
    }
    func testURLSanitizationPreservesEncodedQueryAndIPv6Authority() async {
        let raw =
            "https://wifi.sky.com/login?ssid=Example Guest&mac=02:00:00:00:00:03&url=http%3A%2F%2Fcaptive.apple.com%2Fhotspot-detect.html"
        let url = PortalRequestURL.url(raw)!
        XCTAssertFalse(url.absoluteString.contains(" "))
        XCTAssertTrue(url.absoluteString.contains("ssid=Example%20Guest"))
        XCTAssertTrue(url.absoluteString.contains("mac=02:00:00:00:00:03"))
        XCTAssertTrue(url.absoluteString.contains("url=http%3A%2F%2F"))
        XCTAssertFalse(url.absoluteString.contains("%253A"))
        XCTAssertEqual(PortalRequestURL.url(url.absoluteString), url)
        let client = MockHTTP([h.response("<h1>Welcome</h1>", url.absoluteString)])
        _ = await h.workflow(client).login(
            url: url, identity: h.identity, network: NetworkSnapshot())
        let sent = await client.sent()
        XCTAssertEqual(sent.first?.url, url)
        let ipv6 = URL(string: "https://[2001:db8::1]:8443/login?q=two words")!
        XCTAssertTrue(ipv6.absoluteString.contains("[2001:db8::1]:8443"))
        XCTAssertEqual(URL(string: ipv6.absoluteString), ipv6)
    }
    func testActualIPv6AndHostnameDestinationBoundaries() async {
        for target in [
            "https://[::1]/", "https://[fd00::1]/", "https://[fc00::1]/", "https://[fe80::1]/",
            "https://[::]/", "https://x.localhost/", "https://x.local/", "https://127.0.0.1/",
            "https://172.16.0.1/", "javascript:alert(1)",
        ] {
            let client = MockHTTP([
                h.response(
                    "<form action='\(target)' method='post'><input type='email' name='email'></form>"
                )
            ])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, .failed, target)
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1, target)
        }
        let client = MockHTTP([
            h.response(
                "<form action='/grant' method='post'><input type='email' name='email'></form>",
                "http://10.128.128.128/splash"), h.response("Done", "http://10.128.128.128/grant"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "http://10.128.128.128/splash")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
    }
    func testCorrectionLadderOnlyReformatsSameIdentity() {
        XCTAssertEqual(rules.correctionRounds, 3)
        XCTAssertEqual(
            variants("phone", "07700 900123"), ["07700900123", "+447700900123", "00447700900123"])
        XCTAssertEqual(variants("postcode", "sw1a1aa"), ["SW1A 1AA", "SW1A1AA"])
        XCTAssertEqual(
            variants("date_of_birth", "1988-03-14"), ["14/03/1988", "03/14/1988", "14-03-1988"])
        for intent in ["email", "first_name", "address_line_1", "account_password", "unknown"] {
            XCTAssertEqual(variants(intent, "configured value"), [])
        }
        XCTAssertEqual(e164("07700900123", country: "United Kingdom"), "+447700900123")
        XCTAssertEqual(e164("+447700900124", country: "United Kingdom"), "+447700900124")
    }
    func testParseAllFormsAndChooseVisibleIdentityForm() throws {
        let fixture = try String(
            contentsOf: h.fixtures.appendingPathComponent("uk_guest_portal.html"),
            encoding: .utf8)
        let forms = HTMLPage(fixture).forms
        XCTAssertEqual(forms.count, 2)
        let best = try XCTUnwrap(forms.max { $0.score(rules: rules) < $1.score(rules: rules) })
        XCTAssertEqual(best.action, "/guest/connect")
        XCTAssertEqual(
            Set(best.fields.map(\.name)),
            Set([
                "token", "mac", "email", "fname", "surname", "postcode", "terms_accepted",
                "marketing_opt_in", "submit",
            ]))
        let visible = HTMLPage(
            "<form action='/journey/auth/user/form'><input name='email' type='email'><button>Continue</button></form><form action='/journey/register/user'><button type='button'>Back</button><button>Create</button></form>"
        ).forms
        XCTAssertEqual(
            visible.max { $0.score(rules: rules) < $1.score(rules: rules) }?.action,
            "/journey/auth/user/form")
    }
    func testNestedLabelsAutocompleteAndExtendedPersona() throws {
        let fields = try fillFields(
            "<label>Email address<input name='x1' required></label><input name='x2' autocomplete='given-name' required><input name='x3' autocomplete='family-name' required><input name='x4' autocomplete='bday-day' required><input name='x5' autocomplete='bday-month' required><input name='x6' autocomplete='bday-year' required><input name='address_line_1'><input name='address_line_2'><input name='town'><input name='county'><input name='company'><textarea name='reason_for_visit'></textarea>"
        )
        XCTAssertEqual(fields["x1"], h.identity.email)
        XCTAssertEqual(fields["x2"], h.identity.firstName)
        XCTAssertEqual(fields["x3"], h.identity.lastName)
        XCTAssertEqual(fields["x4"], "14")
        XCTAssertEqual(fields["x5"], "03")
        XCTAssertEqual(fields["x6"], "1988")
        for (name, intent) in [
            ("address_line_1", "address_line_1"), ("address_line_2", "address_line_2"),
            ("town", "city"), ("county", "county"), ("company", "company"),
            ("reason_for_visit", "reason_for_visit"),
        ] {
            XCTAssertEqual(fields[name], persona(intent, h.identity), name)
        }
        XCTAssertEqual(
            try fillFields("<input name='opaque' placeholder='Email address'>")["opaque"],
            h.identity.email)
        let aria = try fillFields(
            "<input name='opaque' aria-label='Email address' aria-required='true'><input name='locked' value='Server supplied' readonly required><input name='template' value='Do not send' disabled required>"
        )
        XCTAssertEqual(aria, ["opaque": h.identity.email, "locked": "Server supplied"])
    }
    func testUnknownRequiredSynthesisIsExplicitlyNotAuthorized() throws {
        // Constraints describe a value's shape, not permission to invent its meaning.
        for control in [
            "<input type='url' name='field' required>",
            "<input type='password' name='field' required>",
            "<input type='date' name='field' min='2000-01-01' max='2010-01-01' required>",
            "<input type='number' name='field' min='1000' max='1002' required>",
            "<input inputmode='numeric' name='field' maxlength='4' required>",
            "<input name='field' pattern='\\d{4}' required>",
            "<input name='field' maxlength='5' required>",
            "<input name='field' pattern='[A-Z]{3}-[0-9]{2}' required>",
            "<select name='field' required><option value=''>Select</option><option value='bronze' disabled>Bronze</option><option value='silver'>Silver</option></select>",
            "<input type='radio' name='field' value='trex' disabled required><input type='radio' name='field' value='raptor' required>",
        ] {
            XCTAssertThrowsError(try fillFields(control), control)
        }
        XCTAssertEqual(
            try fillFields("<input type='email' name='field' required>")["field"], h.identity.email)
        XCTAssertEqual(
            try fillFields("<input type='tel' name='field' required>")["field"], h.identity.phone)
    }
    func testHTTP422CorrectionsPreserveDOBPostcodePhone() async {
        for (name, type, value, expected) in [
            ("dob", "text", "1988-03-14", "14/03/1988"),
            ("postcode", "text", "SW1A1AA", "SW1A 1AA"),
            ("mobile", "tel", "07700900123", "+447700900123"),
        ] {
            var person = h.identity
            if name == "postcode" { person.values["FAKE_POSTCODE"] = value }
            let html =
                "<form action='/register' method='post'><input name='\(name)' type='\(type)' required></form>"
            let message =
                name == "postcode" ? "<p class='error'>Please enter a valid postcode</p>" : ""
            let rejected =
                message
                + "<form action='/register' method='post'><input name='\(name)' type='\(type)' aria-invalid='true' required></form>"
            let client = MockHTTP([
                h.response(html), h.response(rejected, status: 422), h.response("Done"),
            ])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: person,
                network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, .submitted, result.reason)
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 3)
            if requests.count == 3 {
                XCTAssertEqual(h.fields(requests[1])[name], value)
                XCTAssertEqual(h.fields(requests[2])[name], expected)
            }
        }
    }
    func testRejectedNameDoesNotInventAnotherIdentity() async {
        let client = MockHTTP([
            h.response("<form method='post'><input name='first_name' required></form>"),
            h.response(
                "<form><input name='first_name' aria-invalid='true' required></form>", status: 422),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "validation_exhausted")
        XCTAssertEqual(result.actions, 1)
        let sent = await client.sent()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(h.fields(sent[1])["first_name"], h.identity.firstName)
    }
    func testOnlyStillRejectedFieldsAppearInFinalValidationStep() async {
        let html =
            "<form method='post'><input name='email' type='email' required><input name='mobile' type='tel' required></form>"
        let both =
            "<form><input name='email' type='email' aria-invalid='true'><input name='mobile' type='tel' aria-invalid='true'></form>"
        let email =
            "<form><input name='email' type='email' aria-invalid='true'><input name='mobile' type='tel'></form>"
        let client = MockHTTP([h.response(html), h.response(both), h.response(email)])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "privacy_email_required")
        XCTAssertEqual(result.actions, 2)
        let last = result.steps.last { $0.phase == "validation" }
        XCTAssertEqual(last?.fields.map(\.intent), ["email"])
    }
    func testDeadlineAndDNSErrorsAreTransportFailures() async {
        let client = MockHTTP([])
        let session = PortalSession(
            client: client, rules: rules, identity: h.identity,
            entry: URL(string: "https://guest.example.net/")!, network: NetworkSnapshot(),
            dataDirectory: URL(fileURLWithPath: "/tmp"), deadline: .distantPast)
        let expired = await session.run()
        XCTAssertEqual(expired.reason, "portal_attempt_deadline_exceeded")
        let sent = await client.sent()
        XCTAssertTrue(sent.isEmpty)
        let failing = FailingPortalHTTP(.cannotFindHost)
        let workflow = PortalWorkflow(
            client: failing, resources: h.resources, dataDirectory: URL(fileURLWithPath: "/tmp"))
        let result = await workflow.login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "portal_dns_unavailable")
        XCTAssertEqual(result.outcome, .failed)
    }
    func testGETFormRetainsExistingQueryAndNeverCreatesPOSTBody() async {
        let client = MockHTTP([
            h.response(
                "<form action='/connect?venue=1' method='get'><input name='email' type='email'></form>"
            ), h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let sent = await client.sent()
        XCTAssertEqual(sent[1].method, "GET")
        XCTAssertNil(sent[1].body)
        let query = Dictionary(
            (URLComponents(url: sent[1].url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map
            { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        XCTAssertEqual(query, ["venue": "1", "email": h.identity.email])
    }
    func testPolicyLabelsAndOptionalChoicesNeverInventIdentifiers() async {
        for label in [
            "Additional mandatory identifier", "Guest reference", "Identification",
            "Your existing membership number", "Loyalty number", "Customer ID",
            "Assigned guest identifier",
        ] {
            let client = MockHTTP([
                h.response(
                    "<form method='post'><label>\(label)<input name='opaque' required></label></form>"
                )
            ])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, .unsupported, label)
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1, label)
        }
        for label in ["Identification: first and last name", "Email identifier"] {
            XCTAssertNotNil(rules.intent(["label": label, "type": "text"]))
        }
        XCTAssertEqual(
            rules.intent(["label": "Are you a Santander customer?", "type": "radio"]),
            "customer_status")
    }
    func testConsentPhaseAndDeclaredPhoneAreSafeStructure() async throws {
        let declared = PortalStructureReporter.describe(
            body:
                "{\"stdFields\":[{\"name\":\"mobile_number\",\"type\":\"phone\",\"requirement\":\"required\"}]}",
            contentType: "application/json", resources: h.resources)
        let fields = try XCTUnwrap(declared["declared_fields"] as? [[String: Any]])
        XCTAssertEqual(fields.first?["type"] as? String, "phone")
        let client = MockHTTP([
            h.response(
                "<form method='post'><input name='terms' type='checkbox'><input name='marketing' type='checkbox'></form>"
            ), h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertTrue(result.steps.contains { $0.phase == "consent" })
        let consent = result.steps.first { $0.phase == "consent" }
        XCTAssertEqual(
            Set(consent?.fields.map(\.category) ?? []),
            Set(["Terms consent", "Marketing declined"]))
    }
}

extension PortalLegacyAuditTests {
    func testCompoundDescriptionsSpecificMeaningsAndConflicts() {
        for label in [
            "Family name and given name together", "Your first and last name", "Name and surname",
            "Surname and name",
        ] {
            XCTAssertEqual(rules.intent(["label": label]), "full_name", label)
        }
        XCTAssertEqual(rules.intent(["label": "Electronic mail address"]), "email")
        XCTAssertEqual(rules.intent(["label": "Electronic device address"]), "address_line_1")
        XCTAssertNil(rules.intent(["label": "Email or telephone"]))
        XCTAssertNil(rules.intent(["label": "Telephone", "name": "email"]))
        XCTAssertEqual(rules.intent(["label": "Telephone", "type": "email"]), "email")
        XCTAssertNil(rules.intent(["label": "Contact destination"]))
        XCTAssertEqual(
            rules.intent([
                "label": "Contact destination", "description": "Your electronic mail address",
            ]), "email")
        for name in ["countryName", "countryOfResidence", "contact_country", "nationalitycode"] {
            XCTAssertEqual(rules.intent(["name": name]), "country")
        }
        XCTAssertNil(rules.intent(["label": "E-mail", "type": "number"]))
        XCTAssertNil(rules.intent(["name": "first_name", "type": "number"]))
        XCTAssertEqual(
            rules.intent(["name": "day", "type": "number", "fieldset": "Date of birth"]),
            "birth_day")
        XCTAssertNil(
            rules.intent([
                "label": "Guest details",
                "description": "Please address this greeting: nombre completo.",
            ]))
        XCTAssertEqual(
            rules.intent([
                "label": "Guest details", "description": "House number and street address",
            ]), "address_line_1")
        XCTAssertEqual(rules.intent(["label": "Your address"]), "address_line_1")
    }
    func testExternalAlertLinksOnlyTheRejectedField() async throws {
        let client = MockHTTP([])
        let session = PortalSession(
            client: client, rules: rules, identity: h.identity,
            entry: URL(string: "https://guest.example.net/")!, network: NetworkSnapshot(),
            dataDirectory: URL(fileURLWithPath: "/tmp"))
        let form = try XCTUnwrap(
            HTMLPage("<form><input type='tel' name='contact' required></form>").forms.first)
        let rejected = await session.testRejectedNames(
            h.response(
                "<aside role='alert'>Telephone: use international format</aside><form><input type='tel' name='contact' required></form>"
            ), formHTML: "<form><input type='tel' name='contact' required></form>")
        XCTAssertEqual(rejected, ["contact"])
        let benign = await session.testRejectedNames(
            h.response(
                "<aside role='alert'>Privacy information</aside><form><input type='tel' name='contact' required></form>"
            ), formHTML: "<form><input type='tel' name='contact' required></form>")
        XCTAssertTrue(benign.isEmpty)
        XCTAssertTrue(
            HTMLPage("<aside role='alert'>Telephone: use international format</aside>").errors
                .contains("Telephone"))
        XCTAssertEqual(form.fields.count, 1)
        _ = session
    }
    func testUnknownOptionalMarketingAndServerValuesRemainUninvented() throws {
        let fields = try fillFields(
            "<input name='optional'><input name='csrf' type='hidden' value='serverval' required><input name='locked' value='server default' readonly required>"
        )
        XCTAssertEqual(fields["optional"] ?? "", "")
        XCTAssertEqual(fields["newsletter_topic"] ?? "", "")
        XCTAssertThrowsError(try fillFields("<input name='newsletter_topic' required>"))
        XCTAssertEqual(fields["csrf"], "serverval")
        XCTAssertEqual(fields["locked"], "server default")
        XCTAssertNil(
            try fillFields(
                "<select name='field'><option value=''>Select</option><option value='bronze'>Bronze</option></select>"
            )["field"])
        XCTAssertNil(
            try fillFields(
                "<input type='radio' name='field' value='trex'><input type='radio' name='field' value='raptor'>"
            )["field"])
        XCTAssertThrowsError(
            try fillFields(
                "<select name='marketing_frequency' required><option value='daily'>Daily</option></select>"
            ))
        XCTAssertThrowsError(
            try fillFields(
                "<input type='radio' name='marketing_channel' value='email' required><input type='radio' name='marketing_channel' value='sms' required>"
            ))
    }
    func testGrantFormTakesPrecedenceAndNeverPostsPromotionAccount() async throws {
        let consent = try String(
            contentsOf: h.fixtures.appendingPathComponent(
                "consent_only_portal.html"), encoding: .utf8)
        let grant = try String(
            contentsOf: h.fixtures.appendingPathComponent(
                "consent_grant_portal.html"), encoding: .utf8)
        let client = MockHTTP([
            h.response(consent, "https://portal.example/guest/"),
            h.response(grant, "https://portal.example/guest/index.asp"),
            h.response(
                "<a href='/account/create'>Create account to get connected</a>",
                "https://promotion.example/"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://portal.example/guest/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        XCTAssertEqual(result.actions, 2)
        let sent = await client.sent()
        XCTAssertEqual(sent.count, 3)
        XCTAssertEqual(sent[2].method, "GET")
        XCTAssertEqual(sent[2].url.host, "gateway.example")
        XCTAssertEqual(sent[2].url.path, "/splash/session/grant")
        let body = h.fields(sent[1])
        XCTAssertEqual(body["email"], "guest@example.com")
        XCTAssertEqual(body["fname"], "Splash")
        XCTAssertEqual(body["tnc"], "tnc")
        XCTAssertEqual(body["client_mac"], "02:00:00:00:00:01")
    }
    func testChallengeAndIdentityBoundariesStopBeforeAnyPOST() async {
        for (html, reason) in [
            (
                "<form><label>SMS verification code<input name='otp'></label></form>",
                "sms_verification"
            ),
            ("<form><input name='otp_field' required></form>", "verification_code_required"),
            (
                "<form><label>Enter your passcode<input name='field1' required></label></form>",
                "verification_code_required"
            ),
            (
                "<p>We've sent a code to your phone. Check your phone and enter it below.</p><form><input name='field1' required></form>",
                "sms_verification"
            ),
            (
                "<form><label>Code<input name='c' maxlength='6' required></label></form>",
                "verification_code_required"
            ),
            (
                "<form><div class='g-recaptcha'></div><input name='email'></form>",
                "captcha_required"
            ),
            (
                "<form><input name='email'><input name='passport_number' required></form>",
                "government_identity_required"
            ),
            (
                "<form><input name='email'><input name='person_being_visited' required></form>",
                "sponsor_approval_required"
            ),
        ] {
            let client = MockHTTP([h.response(html)])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.reason, reason, html)
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1, html)
        }
        let client = MockHTTP([
            h.response(
                "<form method='post'><label>Postcode<input name='post_code' maxlength='8' required></label></form>"
            ), h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let sent = await client.sent()
        XCTAssertEqual(h.fields(sent[1])["post_code"], h.identity.values["FAKE_POSTCODE"])
    }
    func testSocialWrappersAndGuestAlternative() async {
        for label in ["Continue with Google", "Continuer avec Apple", "Facebook"] {
            let client = MockHTTP([h.response("<a href='/jump'>\(label)</a>")])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "social_login_required", label)
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1)
        }
        for target in [
            "https://guest.example.net/oauth/google",
            "https://guest.example.net/jump?next=https%3A%2F%2Faccounts.google.com%2Flogin",
        ] {
            let client = MockHTTP([h.response("", status: 302, headers: ["Location": target])])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "social_login_required")
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1)
        }
        let client = MockHTTP([
            h.response(
                "<a href='/oauth/google'>Continue with Google</a><a href='/guest'>Use free Wi-Fi</a>"
            ), h.response("<form method='post'><input name='email' type='email'></form>"),
            h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let sent = await client.sent()
        XCTAssertEqual(sent[1].url.path, "/guest")
    }
}

extension PortalLegacyAuditTests {
    func testKnownFieldsAddressAutocompleteAndAgeRangesUseObservedChoices() throws {
        let fields = try fillFields(
            "<input name='x1' autocomplete='address-line1' required><input name='x2' autocomplete='address-level2' required><input name='x3' autocomplete='address-level1' required><select name='age_group' required><option value=''>Choose</option><option value='25_34'>25-34</option><option value='35_44'>35-44</option></select><select name='dob_month' required><option value=''>Choose</option><option value='3'>March</option></select>"
        )
        XCTAssertEqual(fields["x1"], persona("address_line_1", h.identity))
        XCTAssertEqual(fields["x2"], persona("city", h.identity))
        XCTAssertEqual(fields["x3"], persona("county", h.identity))
        XCTAssertEqual(fields["age_group"], "35_44")
        XCTAssertEqual(fields["dob_month"], "3")
    }
    func testDormantCaptchaShellHandsOffAndUnknownTableNumberNeverBecomesOTP() async {
        for html in [
            "<div id='app'></div><script>window.portalConfig={captchaProvider:'recaptcha',captchaEnabled:false};</script>",
            "<form method='post'><label>Table Number<input name='table_number' maxlength='4' required></label><input name='email' type='email'></form>",
        ] {
            let client = MockHTTP([h.response(html)])
            let result = await h.workflow(client).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertFalse(
                ["verification_code_required", "captcha_required"].contains(result.reason))
            XCTAssertTrue([.browser, .unsupported].contains(result.outcome))
            let sent = await client.sent()
            XCTAssertEqual(sent.count, 1)
        }
    }
    func testPhoneCorrectionExhaustionHasValueFreeLatestFields() async throws {
        let html =
            "<form method='post'><input name='mobile' type='tel' aria-invalid='true' required></form>"
        let client = MockHTTP([
            h.response(html), h.response(html, status: 422), h.response(html, status: 422),
            h.response(html, status: 422),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "persona_phone_rejected")
        XCTAssertEqual(result.actions, 3)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(
            requests.dropFirst().compactMap { h.fields($0)["mobile"] },
            ["07700900123", "+447700900123", "00447700900123"])
        let safe = String(decoding: try JSONEncoder().encode(result.steps), as: UTF8.self)
        for value in ["07700900123", "+447700900123", "00447700900123", "447700900123"] {
            XCTAssertFalse(safe.contains(value))
        }
        XCTAssertEqual(
            result.steps.last { $0.phase == "validation" }?.fields.map(\.intent), ["phone"])
    }
}

extension PortalSession {
    func testRejectedNames(_ response: HTTPResponse, formHTML: String) -> [String] {
        guard let form = HTMLPage(formHTML).forms.first else { return [] }
        return rejectedFields(response, form: form).map(\.name)
    }
}

import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalStructureReporterTests: XCTestCase {
    let h = PortalWorkflowTests()
    func testHTMLReportExcludesValuesHeadersTitlesLabelsAndQuery() throws {
        let secret = "SecretSentinel987654321"
        let body =
            "<title>\(secret)</title><form action='/guest/connect?session=\(secret)' method='post'><input type='hidden' name='token' value='\(secret)'><label>Email \(secret)<input name='email' type='email' value='\(secret)' required></label><input name='\(secret)' autocomplete='section-\(secret) email' inputmode='\(secret)' value='\(secret)'></form>"
        let report = PortalStructureReporter.describe(
            body: body, contentType: "text/html", resources: h.resources)
        let output = jsonText(report)
        XCTAssertFalse(output.contains(secret))
        XCTAssertFalse(output.contains("session="))
        XCTAssertFalse(output.contains("title"))
        XCTAssertFalse(output.contains("value"))
        let forms = try XCTUnwrap(report["forms"] as? [[String: Any]])
        XCTAssertEqual(forms[0]["action_path"] as? String, "/guest/connect")
        let fields = try XCTUnwrap(forms[0]["fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["name"] as? String, "token")
        XCTAssertEqual(fields[1]["intent"] as? String, "email")
        XCTAssertTrue((fields[2]["name"] as? String)?.hasPrefix("redacted-field-") == true)
    }
    func testJSONReportKeepsSchemaAndHashesUnknownNames() throws {
        let secret = "SecretSentinel987654321"
        let body = jsonText([
            "success": false, "wifiUser": ["password": secret],
            "stdFields": [
                [
                    "name": "mobile_number", "type": "tel", "requirement": "required",
                    "label": secret,
                ]
            ], "validationFieldErrors": ["mobile_number": [secret], secret: [secret]],
            secret: secret,
        ])
        let report = PortalStructureReporter.describe(
            body: body, contentType: "application/json", resources: h.resources)
        let output = jsonText(report)
        XCTAssertFalse(output.contains(secret))
        XCTAssertFalse(output.contains("password"))
        let fields = try XCTUnwrap(report["declared_fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["intent"] as? String, "phone")
        XCTAssertEqual(fields[0]["required"] as? Bool, true)
        XCTAssertEqual((report["validation_fields"] as? [String])?.count, 2)
    }
    func testEmbeddedJourneyAndProviderHints() throws {
        let body =
            "<script>window.journeyData={\"stdFields\":[{\"name\":\"fname\",\"requirement\":\"required\"}],\"venue\":{\"name\":\"Private Venue\"}};</script>network-auth.com"
        let report = PortalStructureReporter.describe(
            body: body, contentType: "text/html", resources: h.resources)
        XCTAssertEqual(
            report["provider_hints"] as? [String], ["wireless_social", "meraki_external_splash"])
        XCTAssertFalse(jsonText(report).contains("Private Venue"))
        let fields = try XCTUnwrap(report["declared_fields"] as? [[String: Any]])
        XCTAssertEqual(fields[0]["intent"] as? String, "first_name")
    }
    func testTemplateHashIgnoresTokenRotation() {
        let a = PortalStructureReporter.describe(
            body:
                "<form><input name='csrf' type='hidden' value='one'><input name='email' type='email'></form>",
            contentType: "text/html", resources: h.resources)
        let b = PortalStructureReporter.describe(
            body:
                "<form><input name='csrf' type='hidden' value='two'><input name='email' type='email'></form>",
            contentType: "text/html", resources: h.resources)
        XCTAssertEqual(a["template_sha256"] as? String, b["template_sha256"] as? String)
    }
    func testUnknownRouteAndMetadataCannotLeakSentinels() {
        let secret = "SecretSentinel"
        let report = PortalStructureReporter.describe(
            body:
                "<form action='/\(secret)/connect'><input name='email' type='\(secret)' autocomplete='\(secret)' inputmode='\(secret)' maxlength='999999999999999' pattern='\(secret)'></form>",
            contentType: "text/html", resources: h.resources)
        XCTAssertFalse(jsonText(report).contains(secret))
    }
    func testMalformedInputAndLimitsRemainJSONSerializable() throws {
        let report = PortalStructureReporter.describe(
            body: String(
                repeating: "<form><input name='email' type='email' required></form>", count: 40),
            contentType: "text/html", resources: h.resources)
        XCTAssertEqual((report["forms"] as? [Any])?.count, 20)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: report))
    }
}

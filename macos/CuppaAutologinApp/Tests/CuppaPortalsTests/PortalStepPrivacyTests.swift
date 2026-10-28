import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalStepPrivacyTests: XCTestCase {
    let h = PortalWorkflowTests()
    func testStepsHaveUsefulSemanticCategoriesWithoutIdentityOrRawLabels() async throws {
        let secret = "SecretSentinelXYZ"
        var identity = h.identity
        identity.values["FAKE_EMAIL"] = "SecretSentinelXYZ@example.net"
        let html =
            "<form method='post'><label>\(secret) Email<input name='email' type='email' required></label><input name='\(secret)' type='hidden' value='\(secret)'><label>Terms<input name='terms' type='checkbox' value='yes' required></label><label>Marketing offers<input name='marketing' type='checkbox' checked></label></form>"
        let client = MockHTTP([h.response(html), h.response("Done")])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: identity,
            network: NetworkSnapshot())
        let bytes = try JSONEncoder().encode(result.steps)
        let encoded = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(identity.email))
        XCTAssertFalse(encoded.contains("example.net"))
        let fields = result.steps.flatMap(\.fields)
        XCTAssertTrue(fields.contains { $0.intent == "email" && $0.category == "Persona email" })
        XCTAssertTrue(fields.contains { $0.category == "Server-provided" })
        XCTAssertTrue(fields.contains { $0.category == "Marketing declined" })
        XCTAssertTrue(fields.contains { $0.category == "Terms consent" })
        XCTAssertTrue(
            fields.allSatisfy {
                $0.name.hasPrefix("field-") && $0.label.isEmpty && $0.placeholder.isEmpty
            })
    }
    func testUnknownRequiredDiagnosticPreservesMissingMeaningWithoutRawFieldName() async throws {
        let client = MockHTTP([
            h.response("<form><input name='PrivateIdentifierXYZ' required></form>")
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.reason, "requires_browser")
        XCTAssertTrue(
            result.steps.flatMap(\.fields).contains {
                $0.required && $0.missing && $0.intent == "unknown"
            })
        XCTAssertFalse(
            String(decoding: try JSONEncoder().encode(result.steps), as: UTF8.self).contains(
                "PrivateIdentifierXYZ"))
    }
    func testFormatCorrectionDiagnosticIsValueFree() async throws {
        let client = MockHTTP([
            h.response("<form method='post'><input name='phone' type='tel' required></form>"),
            h.response("{\"validationFieldErrors\":{\"phone\":[\"invalid\"]}}"), h.response("Done"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertTrue(
            result.steps.contains {
                $0.phase == "validation" && $0.status == "rejected"
                    && $0.fields.contains {
                        $0.intent == "phone" && $0.category == "Format correction"
                    }
            })
        let encoded = String(decoding: try JSONEncoder().encode(result.steps), as: UTF8.self)
        XCTAssertFalse(encoded.contains(h.identity.phone))
        XCTAssertFalse(encoded.contains("447700900123"))
    }
}

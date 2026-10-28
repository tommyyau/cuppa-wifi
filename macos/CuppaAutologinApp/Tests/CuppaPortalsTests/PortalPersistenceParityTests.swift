import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalPersistenceParityTests: XCTestCase {
    let h = PortalWorkflowTests()
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testSchemaHashMatchesHistoricalPythonProtocol() throws {
        let form = try XCTUnwrap(
            HTMLPage(
                "<form method='post'><input name='token' type='hidden' value='rotating'><input name='email' type='email' required></form>"
            ).forms.first)
        XCTAssertEqual(
            form.signature(rules: PortalRules(resources: h.resources)),
            "4a1a8ade43c813a8ce0787657fb83c9ef5a1bce68344f93f286ff11ab626d8cd")
    }
    func testExplicitCredentialsExactOriginAndPrivatePermissions() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("account-credentials.json")
        try Data(
            jsonText([
                [
                    "origin": "https://guest.example.net:443", "operation": "existing",
                    "username": "chosen-user", "password": "Secret123",
                ]
            ]).utf8
        ).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let html =
            "<form action='/login' method='post'><input name='username' required><input type='password' name='password' autocomplete='current-password' required></form>"
        let client = MockHTTP([h.response(html)])
        let workflow = PortalWorkflow(client: client, resources: h.resources, dataDirectory: dir)
        let result = await workflow.login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertEqual(result.reason, "account_credentials_requires_browser")
        XCTAssertFalse(String(describing: result).contains("Secret123"))
        XCTAssertFalse(String(describing: result).contains("chosen-user"))
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let deniedClient = MockHTTP([h.response(html)])
        let denied = await PortalWorkflow(
            client: deniedClient, resources: h.resources, dataDirectory: dir
        ).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(denied.reason, "account_credentials_required")
    }
    func testCredentialsWrongPortNeverAuthorizes() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("account-credentials.json")
        try Data(
            jsonText([
                [
                    "origin": "https://guest.example.net:443", "operation": "existing",
                    "username": "chosen-user", "password": "Secret123",
                ]
            ]).utf8
        ).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        for destination in [
            "http://guest.example.net/", "https://other.example.net/",
            "https://guest.example.net:444/",
        ] {
            let client = MockHTTP([
                h.response(
                    "<form><input type='password' name='password' autocomplete='current-password' required></form>",
                    destination)
            ])
            let result = await PortalWorkflow(
                client: client, resources: h.resources, dataDirectory: dir
            ).login(
                url: URL(string: destination)!, identity: h.identity, network: NetworkSnapshot())
            XCTAssertEqual(result.reason, "account_credentials_required", destination)
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1)
        }
    }
    func testVerifiedBrowserStrategyOnlySameSchemaAndFreshHost() async throws {
        let dir = try temporary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let html = "<form method='post'><input name='email' type='email' required></form>"
        let form = try XCTUnwrap(HTMLPage(html).forms.first)
        let signature = form.signature(rules: PortalRules(resources: h.resources))
        for (age, host, expected) in [
            (0.0, "guest.example.net", true), (31.0 * 86400, "guest.example.net", false),
            (0.0, "other.example.net", false), (-60.0, "guest.example.net", false),
        ] {
            try Data(
                jsonText([
                    "version": 1,
                    "strategies": [
                        [
                            "host": host, "signature": signature, "execution": "browser",
                            "verified_at": Date().timeIntervalSince1970 - age,
                        ]
                    ],
                ]).utf8
            ).write(to: dir.appendingPathComponent("portal_learning.json"))
            let client = MockHTTP([h.response(html), h.response("Done")])
            let result = await PortalWorkflow(
                client: client, resources: h.resources, dataDirectory: dir
            ).login(
                url: URL(string: "https://guest.example.net/")!, identity: h.identity,
                network: NetworkSnapshot())
            XCTAssertEqual(result.outcome, expected ? .browser : .submitted)
        }
    }
    func testLoneConstrainedCodeAndSponsorBoundaryBeforeSubmission() async {
        for (html, reason) in [
            (
                "<form><label>Code<input name='c' maxlength='6' required></label></form>",
                "verification_code_required"
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
            XCTAssertEqual(result.reason, reason)
            let requests = await client.sent()
            XCTAssertEqual(requests.count, 1)
        }
    }
    func testCorrectionRefreshesHiddenTokenAndPreservesAcceptedField() async {
        let original =
            "<form action='/register' method='post'><input name='csrf' type='hidden' value='old-token'><input name='mystery' value='accepted-choice' required><input name='phone' type='tel' required></form>"
        let rejected =
            "<aside role='alert'>Telephone invalid format</aside>"
            + original.replacingOccurrences(of: "old-token", with: "new-token")
        let client = MockHTTP([
            h.response(original), h.response(rejected, "https://guest.example.net/register"),
            h.response("Done", "https://guest.example.net/register"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        guard requests.count >= 3 else {
            XCTFail("Missing correction request: " + result.reason)
            return
        }
        XCTAssertEqual(h.fields(requests[2])["csrf"], "new-token")
        XCTAssertEqual(h.fields(requests[2])["mystery"], "accepted-choice")
        XCTAssertEqual(h.fields(requests[2])["phone"], "+447700900123")
    }
}

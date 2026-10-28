import CuppaCore
import Foundation
import XCTest

@testable import CuppaPortals

@MainActor
final class PortalNavigationParityTests: XCTestCase {
    let h = PortalWorkflowTests()
    func testImageButtonTitleNavigatesAndRetainsCandidateAction() async {
        let client = MockHTTP([
            h.response(
                "<a href='/grant' title='Continue to the Internet'><img src='/button.png'></a>"),
            h.response("Done", "https://guest.example.net/grant"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertTrue(result.pendingSubmission)
        XCTAssertEqual(result.actions, 1)
    }
    func testReviewedMerakiNullGrantKeepsAmbiguousActionAndHop() async {
        let url = "https://eu.network-auth.com/splash/costa/"
        let html =
            "<a title='Continue to the Internet' href='/splash/costa/grant?continue_url=https%3A%2F%2Fwww.costa.co.uk%2Fwifi-connected'><img src='/button.png'></a>"
        let client = MockHTTP([h.response(html, url)])
        let result = await h.workflow(client).login(
            url: URL(string: url)!, identity: h.identity, network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertEqual(result.reason, "meraki_grant_transport_ambiguous")
        XCTAssertTrue(result.pendingSubmission)
        XCTAssertEqual(result.hops.count, 2)
        XCTAssertNil(result.hops.last?.response)
    }
    func testArbitraryFailedConnectLinkDoesNotBecomeTrustedGrant() async {
        let client = MockHTTP([
            h.response("<a href='/grant?continue_url=https://example.net'>Connect</a>")
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .failed)
        XCTAssertEqual(result.reason, "portal_transport_unavailable")
        XCTAssertNotEqual(result.reason, "meraki_grant_transport_ambiguous")
    }
    func testRequestBudgetSpansRedirectsAndStaticStages() async {
        let responses = (0..<20).map { n in
            h.response(
                "<form action='/step\(n)' method='post'><input name='email' type='email'></form>",
                "https://guest.example.net/step\(n)")
        }
        let client = MockHTTP(responses)
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/step0")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        let requests = await client.sent()
        XCTAssertLessThanOrEqual(requests.count, 12)
        XCTAssertTrue(
            requests.allSatisfy { $0.timeout <= 10 && $0.timeout > 0 && !$0.followRedirects })
    }
    func testTermsLinkAloneDoesNotAuthorizeGrant() async {
        let client = MockHTTP([h.response("<a href='/terms'>Terms and conditions</a>")])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertFalse(result.pendingSubmission)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 1)
    }
    func testMetaRefreshAfterSubmissionIsFollowedBeforeCandidateReturn() async {
        let client = MockHTTP([
            h.response("<form method='post'><input name='email' type='email'></form>"),
            h.response("<meta http-equiv='refresh' content='0;url=/grant'>"),
            h.response("Done", "https://guest.example.net/grant"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 3)
    }
    func testFreeGuestAlternativePreservesOrdinaryPathFromAccountGate() async {
        let client = MockHTTP([
            h.response(
                "<form><input name='password' type='password' autocomplete='current-password' required></form><a href='/guest'>Use free Wi-Fi</a>"
            ),
            h.response(
                "<form action='/connect' method='post'><input name='email' type='email'></form>",
                "https://guest.example.net/guest"),
            h.response("Done", "https://guest.example.net/connect"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .submitted, result.reason)
        let requests = await client.sent()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].method, "GET")
        XCTAssertNil(h.fields(requests[2])["password"])
    }
    func testMarketingDropdownDeclinesActualOptionAndUnlabelledCheckboxOmitted() throws {
        let rules = PortalRules(resources: h.resources)
        let page = HTMLPage(
            "<form><label>Marketing offers<select name='offers'><option value='yes' selected>Yes</option><option value='declined'>No thanks</option></select></label><input type='checkbox' name='unexplained' checked></form>"
        )
        let fields = Dictionary(
            try fill(XCTUnwrap(page.forms.first), identity: h.identity, rules: rules),
            uniquingKeysWith: { _, last in last })
        XCTAssertEqual(fields["offers"], "declined")
        XCTAssertNil(fields["unexplained"])
    }

}

extension PortalNavigationParityTests {
    func testMetaAndScriptRedirectsRemainZeroActionBrowserCandidate() async {
        let client = MockHTTP([
            h.response("<meta content='0;url=/step-two' http-equiv='refresh'>"),
            h.response(
                "<script>location='/landing';</script>", "https://guest.example.net/step-two"),
            h.response("<html>No form needed</html>", "https://guest.example.net/landing"),
        ])
        let result = await h.workflow(client).login(
            url: URL(string: "https://guest.example.net/")!, identity: h.identity,
            network: NetworkSnapshot())
        XCTAssertEqual(result.outcome, .browser)
        XCTAssertEqual(result.reason, "no_static_form_found")
        XCTAssertEqual(result.actions, 0)
        XCTAssertFalse(result.pendingSubmission)
        XCTAssertEqual(result.hops.count, 3)
        let requests = await client.sent()
        XCTAssertEqual(requests.map(\.url.path), ["/", "/step-two", "/landing"])
        XCTAssertTrue(requests.allSatisfy { $0.method == "GET" && $0.body == nil })
    }
}

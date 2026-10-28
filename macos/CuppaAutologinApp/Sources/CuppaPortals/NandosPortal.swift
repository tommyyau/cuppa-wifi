import CuppaCore
import Foundation

/// Nando's reviewed controller grant; no Persona is sent to an untrusted grant host.
extension PortalSession {
    func nandos(_ landing: HTTPResponse) async throws {
        guard let parts = URLComponents(url: landing.url, resolvingAgainstBaseURL: false) else {
            throw PortalPolicyError(reason: "nandos_invalid_grant_parameters")
        }
        let query = Dictionary(
            (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first })
        guard let base = query["base_grant_url"], let grant = URL(string: base),
            grant.scheme == "https", (grant.host ?? "").hasSuffix(".network-auth.com"),
            grant.user == nil, grant.password == nil,
            let fallback = query["user_continue_url"], let continueURL = URL(string: fallback),
            safeURL(continueURL)
        else { throw PortalPolicyError(reason: "nandos_invalid_grant_parameters") }
        var continuation = fallback
        if let mac = query["node_mac"], matches("^[0-9a-f:.-]{6,64}$", mac) {
            continuation =
                "https://free-wifi.nandos.co.uk/connected/"
                + (mac.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")
        }
        var target = URLComponents(url: grant, resolvingAgainstBaseURL: false)!
        target.queryItems = [URLQueryItem(name: "continue_url", value: continuation)]
        target.fragment = nil
        actions += 1
        submitted = true
        recordAction(method: "GET")
        let response = try await request(target.url!)
        guard (200..<400).contains(response.status) else {
            throw PortalPolicyError(reason: "nandos_grant_request_failed")
        }
    }
}

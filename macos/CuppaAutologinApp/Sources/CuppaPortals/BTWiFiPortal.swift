import CuppaCore
import Foundation

/// BT modern AJAX registration and legacy form continuation.
extension PortalSession {
    func bt(_ landing: HTTPResponse) async throws {
        venue =
            matches("Santander", landing.text)
            ? "Santander" : matches("Picturehouse", landing.text) ? "Picturehouse" : "BT Wi-Fi"
        if !hostMatches(landing.url.host ?? "", "portal.btwifi.com") {
            try await btLegacy(landing)
            return
        }
        let page = HTMLPage(landing.text)
        let form = page.forms.first {
            $0.fields.contains {
                $0.name == "form_type" && $0.value.lowercased() == "registrationform"
            }
        }
        if let reason = boundary(page, html: landing.text, form: form, rules: rules) {
            throw PortalPolicyError(reason: reason)
        }
        guard let form else { throw PortalPolicyError(reason: "bt_wifi_registration_form_missing") }
        recordForm(form)
        let target = try resolve(form.action, base: landing.url)
        guard sameOrigin(target, landing.url) else {
            throw PortalPolicyError(reason: "bt_wifi_untrusted_registration_endpoint")
        }
        // These provider questions have reviewed No/Co-working answers; fill
        // other controls normally so unknown mandatory metadata still stops.
        let providerChoices = form.fields.filter {
            $0.type == "select" && matches("customer|why.*visit|reason.*visit|visiting", $0.wording)
        }
        var fields = try fill(
            HTMLForm(
                node: form.node,
                fields: form.fields.filter { field in
                    !providerChoices.contains { $0.node === field.node }
                }), identity: identity, rules: rules)
        for f in form.fields where f.type == "select" {
            let desired: [String]
            if matches("customer", f.wording) {
                desired = ["No"]
            } else if matches("why.*visit|reason.*visit|visiting", f.wording) {
                desired = ["Co-working", "Guest Wi-Fi", "Visiting", "Other"]
            } else {
                continue
            }
            if let option = f.options.first(where: {
                !$0.disabled
                    && desired.map { $0.lowercased() }.contains(
                        $0.text.trimmingCharacters(in: .whitespaces).lowercased())
            }) {
                fields.removeAll { $0.0 == f.name }
                fields.append((f.name, option.value))
            }
        }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        components.queryItems =
            (components.queryItems ?? []).filter { $0.name != "marketing" } + [
                URLQueryItem(name: "marketing", value: "0")
            ]
        let response = try await post(
            components.url!, fields,
            headers: [
                "X-Requested-With": "XMLHttpRequest",
                "Accept": "application/json, text/javascript, */*; q=0.01",
            ])
        if let json = object(response.text) {
            guard json["success"] as? Bool == true else {
                throw PortalPolicyError(reason: "bt_wifi_registration_rejected")
            }
            if let value = json["url"] as? String, !value.isEmpty {
                guard let redirect = try? resolve(value, base: response.url) else {
                    throw PortalPolicyError(reason: "bt_wifi_untrusted_grant_redirect")
                }
                // A browsing destination is not a portal grant. Let the engine
                // verify the already-submitted registration without fetching it.
                if redirect.host == landing.url.host
                    || hostMatches(redirect.host ?? "", "btwifi.com")
                    || (redirect.host ?? "").hasSuffix(".bt.com")
                {
                    let grant = try await request(redirect)
                    guard (200..<400).contains(grant.status) else {
                        throw PortalPolicyError(reason: "bt_wifi_grant_redirect_failed")
                    }
                }
            }
        } else if HTMLPage(response.text).forms.contains(where: {
            $0.fields.contains {
                $0.name == "form_type" && $0.value.lowercased() == "registrationform"
            }
        }) {
            throw PortalPolicyError(reason: "bt_wifi_registration_rejected")
        }
    }
    func btLegacy(_ landing: HTTPResponse) async throws {
        if matches(
            "you are now connected|is-online.{0,100}is-post_auth|is-post_auth.{0,100}is-online",
            landing.text)
        {
            return
        }
        func legacy(_ html: String, path: String, field: String) -> HTMLForm? {
            HTMLPage(html).forms.first { f in
                guard let u = URL(string: f.action) else { return false }
                return u.host == "reg.btwifi.com" && u.scheme == "https"
                    && (u.port == nil || u.port == 443) && u.path == path
                    && f.fields.contains { $0.name == field }
            }
        }
        guard
            let check = legacy(
                landing.text, path: "/registration/check", field: "sessionValidation"),
            let checkURL = URL(string: check.action)
        else { throw PortalPolicyError(reason: "bt_wifi_get_online_form_missing") }
        if let reason = boundary(
            HTMLPage(landing.text), html: landing.text, form: check, rules: rules)
        {
            throw PortalPolicyError(reason: reason)
        }
        recordForm(check)
        let response = try await post(checkURL, try fill(check, identity: identity, rules: rules))
        if matches("you are now connected|is-online.{0,100}is-post_auth", response.text) { return }
        guard
            let registration = legacy(response.text, path: "/registration", field: "detail_email"),
            let registrationURL = URL(string: registration.action)
        else { throw PortalPolicyError(reason: "bt_wifi_legacy_registration_form_missing") }
        recordForm(registration)
        let connected = try await post(
            registrationURL, try fill(registration, identity: identity, rules: rules))
        guard
            matches(
                "you are now connected|is-online.{0,100}is-post_auth|is-post_auth.{0,100}is-online",
                connected.text)
        else { throw PortalPolicyError(reason: "bt_wifi_registration_rejected") }
    }
}

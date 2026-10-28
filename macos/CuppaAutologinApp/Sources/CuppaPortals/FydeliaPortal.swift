import CuppaCore
import Foundation

/// Fydelia registration preserves observed UniFi controller parameters and consent.
extension PortalSession {
    func fydelia(_ landing: HTTPResponse) async throws {
        venue = matches("black[\\s_-]*sheep", landing.text) ? "Black Sheep Coffee" : "Fydelia"
        let page = HTMLPage(landing.text)
        let form = page.forms.first {
            Set($0.fields.map(\.name)).isSuperset(of: ["loginMethod", "userEmail", "phone_number"])
        }
        if let reason = boundary(page, html: landing.text, form: form, rules: rules) {
            throw PortalPolicyError(reason: reason)
        }
        guard let form else { throw PortalPolicyError(reason: "fydelia_splash_form_missing") }
        recordForm(form)
        let target = try resolve(form.action, base: landing.url)
        guard target.scheme == "https", sameOrigin(target, landing.url) else {
            throw PortalPolicyError(reason: "fydelia_untrusted_form_endpoint")
        }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)!
        if components.percentEncodedQuery == nil {
            components.percentEncodedQuery =
                URLComponents(url: entry, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        }
        var fields = try fill(form, identity: identity, rules: rules)
        func set(_ name: String, _ value: String) {
            fields.removeAll { $0.0 == name }
            fields.append((name, value))
        }
        let prefix = fields.first { $0.0 == "phone_number_prefix" }?.1 ?? ""
        var phone = identity.phone.filter(\.isNumber)
        if prefix == "44" || prefix == "+44" {
            if phone.hasPrefix("0044") {
                phone = String(phone.dropFirst(4))
            } else if phone.hasPrefix("44") {
                phone = String(phone.dropFirst(2))
            } else if phone.hasPrefix("0") {
                phone = String(phone.dropFirst())
            }
        }
        set("phone_number", phone)
        for name in ["dobD", "dobM", "dobY"] where fields.contains(where: { $0.0 == name }) {
            set(name, "-")
        }
        if matches("fod_2_step_marketing_js\\s*=\\s*true", landing.text)
            && matches("marketing_invoke_moment\\s*=\\s*['\"]form_submission['\"]", landing.text)
        {
            set("2_step_marketing_chosen", "true")
        }
        fields.removeAll {
            ["Offer", "subscribe_email", "subscribe_sms", "adcard_yes"].contains($0.0)
        }
        _ = try await post(components.url!, fields)
        let query = URLComponents(url: entry, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let value = ["url", "redirect", "continue_url"].compactMap({ key in
            query.first { $0.name == key }?.value
        }).first,
            let continuation = URL(string: value), safeURL(continuation, from: landing.url)
        {
            _ = try await request(continuation)
        }
        // The engine owns the UniFi settle/probe phase after these actions.
    }
}

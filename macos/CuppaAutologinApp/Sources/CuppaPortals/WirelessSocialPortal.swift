import CuppaCore
import Foundation

/// Executes the observed Wireless Social journey graph, including returning users
/// and identity-preserving format corrections. Internet verification belongs to the engine.
extension PortalSession {
    func wireless(_ landing: HTTPResponse) async throws {
        guard let journey = extractJourney(landing.text) else {
            throw PortalPolicyError(reason: "journey_data_missing")
        }
        let metadata = journey["journeyMetaData"] as? [String: Any] ?? [:]
        let venueData = journey["venue"] as? [String: Any] ?? [:]
        venue =
            (metadata["journey_activity_data"] as? [String: Any])?["ssid"] as? String ?? venueData[
                "name"] as? String ?? "Wireless Social"
        let emailDomain =
            identity.email.split(separator: "@").last.map(String.init)?.lowercased() ?? ""
        if !identity.email.contains("@")
            || ["example.com", "example.net", "example.org", "invalid", "localhost", "test"]
                .contains(emailDomain)
        {
            throw PortalPolicyError(reason: "privacy_email_required")
        }
        let endpoints = windowStrings(landing.text)
        func endpoint(_ key: String, _ fallback: String) throws -> URL {
            let url = try resolve(endpoints[key] ?? fallback, base: landing.url)
            guard sameOrigin(url, landing.url) else {
                throw PortalPolicyError(reason: "wireless_social_untrusted_" + key + "_endpoint")
            }
            return url
        }
        func progress(_ phase: String) -> String {
            let now = ISO8601DateFormatter().string(from: Date())
            var p: [String: Any] = [
                "auths": [["form": now]],
                "authStatuses": [["authType": "form", "success": true, "occurredAt": now]],
            ]
            if phase != "auth" { p["ws"] = ["ws-profile": now] }
            if ["dataset", "postauth", "end"].contains(phase) {
                p["ws"] = ["ws-profile": now, "dataset-consent": now]
            }
            if let sequence = (journey["journeyLogic"] as? [String: Any])?["sequence"]
                as? [String: [String: Any]]
            {
                let steps = sequence.sorted { $0.key < $1.key }.compactMap {
                    key, node -> [String: String]? in
                    guard let type = node["type"] as? String,
                        type == "Page"
                            || ["postauth", "end"].contains(phase) && type == "PostStart"
                    else { return nil }
                    return ["step": key, "visitedAt": now, "type": type]
                }
                if !steps.isEmpty { p["journey"] = steps }
            }
            return jsonText(p)
        }
        var account = try await postJSON(
            try endpoint("wsAuthFormUrl", "/journey/auth/user/form"),
            [("email", identity.email), ("ws_journey_login_progress", progress("auth"))])
        guard account["success"] as? Bool == true else {
            throw PortalPolicyError(
                reason: (account["invEm"] as? Bool == true
                    || validationNames(account).contains(where: { canonical($0) == "email" }))
                    ? "privacy_email_required" : "wireless_social_auth_rejected")
        }
        guard var user = wifiUser(account) else {
            throw PortalPolicyError(reason: "wireless_social_missing_user_session")
        }
        let required =
            (account["stdFields"] as? [[String: Any]] ?? journey["stdFields"] as? [[String: Any]]
            ?? []).filter { ($0["requirement"] as? String)?.lowercased() == "required" }
        var profileSubmitted = false
        if !required.isEmpty {
            var values: [(String, String)] = []
            var intents: [String: String] = [:]
            for field in required {
                let name = field["name"] as? String ?? ""
                var descriptor = [
                    "name": name, "type": field["type"] as? String ?? "text",
                    "label": field["label"] as? String ?? "",
                    "placeholder": field["placeholder"] as? String ?? "",
                ]
                if [
                    "fname", "lname", "firstname", "lastname", "mobile", "mobilenumber", "name",
                    "fullname", "dateofbirth", "dob", "address", "address1", "address2", "town",
                ].contains(canonical(name)) {
                    let aliases = [
                        "fname": "first_name", "firstname": "first_name", "lname": "last_name",
                        "lastname": "last_name", "mobile": "phone", "mobilenumber": "phone",
                        "name": "full_name", "fullname": "full_name",
                        "dateofbirth": "date_of_birth", "dob": "date_of_birth",
                        "address": "address_line_1", "address1": "address_line_1",
                        "address2": "address_line_2", "town": "city",
                    ]
                    descriptor["autocomplete"] = nil
                    guard let intent = aliases[canonical(name)],
                        let value = persona(intent, identity)
                    else { throw PortalPolicyError(reason: "unknown_required_field") }
                    values.append(
                        (
                            name,
                            intent == "phone"
                                ? e164(
                                    value, country: persona("country", identity) ?? "United Kingdom"
                                ) : value
                        ))
                    intents[name] = intent
                } else {
                    guard !name.isEmpty, let intent = rules.intent(descriptor),
                        let value = persona(intent, identity)
                    else { throw PortalPolicyError(reason: "unknown_required_field") }
                    values.append(
                        (
                            name,
                            intent == "phone"
                                ? e164(
                                    value, country: persona("country", identity) ?? "United Kingdom"
                                ) : value
                        ))
                    intents[name] = intent
                }
            }
            guard let authMethod = user["authMethod"] as? String,
                let authIdentifier = user["authMethodIdentifier"] as? String, !authMethod.isEmpty,
                !authIdentifier.isEmpty
            else { throw PortalPolicyError(reason: "wireless_social_missing_auth_identity") }
            values += [
                ("authMethod", authMethod), ("authMethodIdentifier", authIdentifier),
                ("ws_journey_login_progress", progress("profile")), ("ws_ds_std_proc", "1"),
            ]
            if let uuid = user["uuid"] as? String { values.append(("ws_uuid", uuid)) }
            let target = try endpoint("wsProfileUrl", "/journey/register/user")
            for round in 0...rules.correctionRounds {
                account = try await postJSON(target, values)
                if account["success"] as? Bool == true {
                    profileSubmitted = true
                    break
                }
                let errors = validationNames(account)
                record(
                    PortalStep(
                        phase: "validation", title: "Provider rejected field format",
                        detail: "Only the configured Persona is retained", status: "rejected",
                        fields: intents.keys.filter { key in
                            errors.contains { canonical($0) == canonical(key) }
                        }.sorted().prefix(100).map {
                            schemaField(
                                $0, intent: intents[$0], category: "Format correction",
                                required: true)
                        }))
                if account["invEm"] as? Bool == true
                    || errors.contains(where: { errorName in
                        canonical(errorName) == "email"
                            || intents.first { canonical($0.key) == canonical(errorName) }?.value
                                == "email"
                    })
                {
                    throw PortalPolicyError(reason: "privacy_email_required")
                }
                var changed = false
                var phoneRejected = false
                for name in intents.keys.sorted()
                where errors.contains(where: { canonical($0) == canonical(name) }) {
                    guard let intent = intents[name],
                        let index = values.firstIndex(where: { $0.0 == name })
                    else { continue }
                    if intent == "phone" { phoneRejected = true }
                    let history = corrections[name] ?? [values[index].1]
                    if round < rules.correctionRounds, let original = persona(intent, identity),
                        let next = ([original] + variants(intent, original)).first(where: {
                            !history.contains($0)
                        }
                        )
                    {
                        values[index].1 = next
                        corrections[name] = history + [next]
                        changed = true
                    }
                }
                if !changed {
                    if phoneRejected {
                        rememberPhone()
                        throw PortalPolicyError(reason: "persona_phone_rejected")
                    }
                    throw PortalPolicyError(reason: "wireless_social_profile_rejected")
                }
            }
            guard profileSubmitted else {
                throw PortalPolicyError(reason: "wireless_social_profile_rejected")
            }
            guard let updated = wifiUser(account) else {
                throw PortalPolicyError(reason: "wireless_social_missing_user_session")
            }
            user = updated
        }
        guard let uuid = user["uuid"] as? String, !uuid.isEmpty else {
            throw PortalPolicyError(reason: "wireless_social_missing_user_session")
        }
        if profileSubmitted {
            var dataset = [("ws_uuid", uuid), ("ws_journey_login_progress", progress("dataset"))]
            if venueData["operatorDataSet"] is [String: Any] { dataset.append(("cdt[op]", "1")) }
            if venueData["sponsorDataSet"] is [String: Any] { dataset.append(("cdt[sp]", "1")) }
            if dataset.count > 2 {
                let response = try await postJSON(
                    try endpoint("wsDataSetUrl", "/journey/user/data-set"), dataset)
                guard response["success"] as? Bool == true else {
                    throw PortalPolicyError(reason: "wireless_social_dataset_rejected")
                }
            }
        }
        let postauth = try await postJSON(
            try endpoint("wsPostAuthUrl", "/cambium/cn-pilot/journey/post-auth/process"),
            [
                ("ws_uuid", uuid), ("ws_journey_meta_data", jsonText(metadata)),
                ("ws_journey_login_progress", progress("postauth")),
            ])
        if postauth["success"] as? Bool == false {
            throw PortalPolicyError(reason: "wireless_social_postauth_rejected")
        }
        if let redirectValue = postauth["redirectUrl"] as? String, !redirectValue.isEmpty {
            let redirect = try resolve(redirectValue, base: landing.url)
            guard sameOrigin(redirect, landing.url),
                redirect.path.hasPrefix("/meraki/mr/post-auth/redirect/")
            else { throw PortalPolicyError(reason: "wireless_social_untrusted_grant_redirect") }
            let grant = try await request(redirect)
            guard (200..<400).contains(grant.status) else {
                throw PortalPolicyError(reason: "wireless_social_grant_redirect_failed")
            }
            if let form = HTMLPage(grant.text).forms.first(where: {
                $0.node.attribute(forName: "name")?.stringValue?.lowercased() == "extredirect"
            }) {
                recordForm(form)
                let target = try resolve(form.action, base: grant.url)
                let fields = form.fields.filter { $0.type == "hidden" && !$0.disabled }.map {
                    ($0.name, $0.value)
                }
                guard form.method == "POST", target.scheme == "https",
                    (target.host ?? "").hasSuffix(".network-auth.com"),
                    target.path.hasPrefix("/splash/"), target.path.hasSuffix("/login"),
                    fields.contains(where: { $0.0 == "username" && !$0.1.isEmpty }),
                    fields.contains(where: { $0.0 == "password" && !$0.1.isEmpty })
                else { throw PortalPolicyError(reason: "wireless_social_untrusted_grant_form") }
                _ = try await post(target, fields)
            }
        }
        let end = try await post(
            try endpoint("wsEndJourneyUrl", "/journey/end/process"),
            [("ws_uuid", uuid), ("ws_journey_login_progress", progress("end"))])
        if object(end.text)?["success"] as? Bool == false {
            throw PortalPolicyError(reason: "wireless_social_end_rejected")
        }
    }
    func postJSON(_ target: URL, _ fields: [(String, String)]) async throws -> [String: Any] {
        let response = try await post(target, fields)
        guard let json = object(response.text) else {
            throw PortalPolicyError(reason: "wireless_social_unrecognised_response")
        }
        return json
    }
}
func wifiUser(_ response: [String: Any]) -> [String: Any]? {
    if let user = response["wifiUser"] as? [String: Any] { return user }
    if let string = response["wifiUser"] as? String { return object(string) }
    return nil
}
func validationNames(_ response: [String: Any]) -> [String] {
    if let errors = response["validationFieldErrors"] as? [String: Any] {
        return Array(errors.keys)
    }
    if let errors = response["validationFieldErrors"] as? [[String: Any]] {
        return errors.compactMap { $0["fieldName"] as? String ?? $0["name"] as? String }
    }
    return []
}
func windowStrings(_ html: String) -> [String: String] {
    let regex = try? NSRegularExpression(
        pattern: "window\\.([A-Za-z0-9_]+)\\s*=\\s*(['\"])(.*?)\\2\\s*;",
        options: [.dotMatchesLineSeparators])
    let text = html as NSString
    return Dictionary(
        (regex?.matches(in: html, range: NSRange(location: 0, length: text.length)) ?? []).map {
            (text.substring(with: $0.range(at: 1)), text.substring(with: $0.range(at: 3)))
        }, uniquingKeysWith: { _, last in last })
}
func extractJourney(_ html: String) -> [String: Any]? {
    guard let range = html.range(of: "window\\.journeyData\\s*=\\s*", options: .regularExpression)
    else { return nil }
    let suffix = html[range.upperBound...]
    var depth = 0
    var quoted = false
    var escaped = false
    var start: String.Index?
    for index in suffix.indices {
        let c = suffix[index]
        if quoted {
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                quoted = false
            }
            continue
        }
        if c == "\"" {
            quoted = true
            continue
        }
        if c == "{" {
            if depth == 0 { start = index }
            depth += 1
        }
        if c == "}" {
            depth -= 1
            if depth == 0, let start { return object(String(suffix[start...index])) }
        }
        if start == nil && !c.isWhitespace && c != "{" { return nil }
    }
    return nil
}

import CryptoKit
import CuppaCore
import Foundation

struct HTMLField {
    let node: XMLElement
    let descriptor: [String: String]
    var name: String { node.attribute(forName: "name")?.stringValue ?? "" }
    var type: String { descriptor["type"] ?? "text" }
    var value: String {
        node.attribute(forName: "value")?.stringValue
            ?? (node.name == "textarea" ? node.stringValue ?? "" : "")
    }
    var required: Bool { node.attribute(forName: "required") != nil }
    var disabled: Bool {
        if node.attribute(forName: "disabled") != nil { return true }
        var parent = node.parent
        while let p = parent as? XMLElement {
            if p.name == "fieldset" && p.attribute(forName: "disabled") != nil { return true }
            parent = p.parent
        }
        return false
    }
    var options: [(value: String, text: String, disabled: Bool, selected: Bool)] {
        ((try? node.nodes(forXPath: ".//option")) ?? []).compactMap { element in
            guard let e = element as? XMLElement else { return nil }
            let content = e.stringValue ?? ""
            let label = e.attribute(forName: "label")?.stringValue ?? ""
            let text = label.isEmpty ? content : label
            return (
                e.attribute(forName: "value")?.stringValue ?? content, text,
                e.attribute(forName: "disabled") != nil
                    || (e.parent as? XMLElement)?.attribute(forName: "disabled") != nil,
                e.attribute(forName: "selected") != nil
            )
        }
    }
    var wording: String {
        ["name", "id", "label", "placeholder", "ariaLabel", "description"].map {
            descriptor[$0] ?? ""
        }.joined(separator: " ")
    }
}
struct HTMLForm {
    let node: XMLElement
    let fields: [HTMLField]
    var action: String { node.attribute(forName: "action")?.stringValue ?? "" }
    var method: String { (node.attribute(forName: "method")?.stringValue ?? "get").uppercased() }
    func signature(rules: PortalRules) -> String {
        let shape: [String: Any] = [
            "action": URL(string: action)?.path ?? action,
            "method": node.attribute(forName: "method")?.stringValue ?? "get",
            "fields": fields.filter { $0.type != "hidden" && !$0.disabled }.map {
                f -> [String: Any] in
                let descriptor = f.descriptor.filter {
                    ["name", "id", "label", "type", "autocomplete"].contains($0.key)
                }
                return [
                    "name": f.name.isEmpty ? f.descriptor["id"] ?? "" : f.name, "type": f.type,
                    "intent": rules.intent(descriptor) as Any? ?? NSNull(), "required": f.required,
                    "pattern": f.node.attribute(forName: "pattern")?.stringValue as Any?
                        ?? NSNull(), "options": f.options.map(\.value),
                    "min": f.node.attribute(forName: "min")?.stringValue as Any? ?? NSNull(),
                    "max": f.node.attribute(forName: "max")?.stringValue as Any? ?? NSNull(),
                ]
            },
        ]
        let compact = String(
            decoding: (try? JSONSerialization.data(
                withJSONObject: shape, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data(),
            as: UTF8.self)
        var canonicalJSON = ""
        var quoted = false
        var escaped = false
        for scalar in compact.unicodeScalars {
            if scalar.value > 127 {
                if scalar.value <= 0xffff {
                    canonicalJSON += String(format: "\\u%04x", scalar.value)
                } else {
                    let adjusted = scalar.value - 0x10000
                    canonicalJSON += String(
                        format: "\\u%04x\\u%04x", 0xd800 + adjusted / 1024, 0xdc00 + adjusted % 1024
                    )
                }
                continue
            }
            canonicalJSON.unicodeScalars.append(scalar)
            if quoted {
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    quoted = false
                }
            } else if scalar == "\"" {
                quoted = true
            } else if scalar == ":" || scalar == "," {
                canonicalJSON += " "
            }
        }
        return SHA256.hash(data: Data(canonicalJSON.utf8)).map { String(format: "%02x", $0) }
            .joined()

    }
    func browser(_ html: String, rules: PortalRules, profile: [String: Any]) -> Bool {
        if profile["execution"] as? String == "browser" { return true }
        if (profile["browserMarkers"] as? [String] ?? []).contains(where: {
            html.lowercased().contains($0.lowercased())
        }) {
            return true
        }
        if ["data-endpoint", "data-api", "data-submit-url"].contains(where: {
            node.attribute(forName: $0) != nil
        }) {
            return true
        }
        if matches(
            "return\\s+false|preventDefault|fetch|ajax",
            node.attribute(forName: "onsubmit")?.stringValue ?? "")
        {
            return true
        }
        return matches(
            "addEventListener\\s*\\(\\s*['\"]submit['\"]|\\.on\\s*\\(\\s*['\"]submit['\"]", html)
    }
    func score(rules: PortalRules) -> Int {
        if fields.contains(where: {
            $0.type == "search" || ["q", "query", "search"].contains($0.name.lowercased())
        }) {
            return -100
        }
        return fields.filter { !$0.disabled }.reduce(0) { score, f in
            score
                + (["email", "first_name", "last_name", "full_name", "phone", "postcode"].contains(
                    rules.intent(f.descriptor) ?? "") ? 8 : f.type == "submit" ? 2 : 0)
        }
    }
}
struct HTMLPage {
    let document: XMLDocument?
    let forms: [HTMLForm]
    init(_ html: String) {
        // Foundation's HTML tidy parser predates HTML5 and discards unknown
        // containers (including role=alert on aside). Preserve their attributes
        // and hierarchy as neutral divs before parsing.
        let compatible = html.replacingOccurrences(
            of:
                "<(/?)(?:aside|section|article|main|nav|header|footer|figure|figcaption|details|summary)(?=[\\s>])",
            with: "<$1div", options: [.regularExpression, .caseInsensitive])
        // Tidy collapses a whitespace-only option label to an empty attribute.
        // Browsers display the former as blank but use content for the latter.
        // Keep blank labels nonempty and unrecognizable so hidden answer text
        // cannot authorize a marketing choice after that lossy normalization.
        let preservedOptionLabels = compatible.replacingOccurrences(
            of: "(<option\\b[^>]*?\\slabel\\s*=\\s*)(['\"])[ \\t\\r\\n\\f]+\\2",
            with: "$1$2&#8203;$2", options: [.regularExpression, .caseInsensitive])
        document = try? XMLDocument(
            xmlString: preservedOptionLabels, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        guard let document else {
            forms = []
            return
        }
        let all = (try? document.nodes(forXPath: "//*")) ?? []
        let elements = all.compactMap { $0 as? XMLElement }
        let ids = Dictionary(
            elements.compactMap { e -> (String, XMLElement)? in
                guard let id = e.attribute(forName: "id")?.stringValue else { return nil }
                return (id, e)
            }, uniquingKeysWith: { first, _ in first })
        forms = elements.filter { $0.name?.lowercased() == "form" }.prefix(32).map { form in
            let nodes =
                ((try? form.nodes(forXPath: ".//input | .//select | .//textarea | .//button")) ?? [])
                .compactMap { $0 as? XMLElement }.prefix(500)
            let fields = nodes.map { node -> HTMLField in
                let id = node.attribute(forName: "id")?.stringValue ?? ""
                func labelText(_ element: XMLNode) -> String {
                    if element === node { return "" }
                    if element.kind == .text { return element.stringValue ?? "" }
                    return (element.children ?? []).map(labelText).joined(separator: " ")
                }
                let labels = elements.filter {
                    $0.name == "label" && !id.isEmpty
                        && $0.attribute(forName: "for")?.stringValue == id
                }.map { labelText($0) }
                var parent = node.parent
                var wrapping = ""
                var legend = ""
                while let p = parent as? XMLElement, p !== form {
                    if p.name == "label" { wrapping = labelText(p) }
                    if p.name == "fieldset" {
                        legend = ((try? p.nodes(forXPath: "./legend")) ?? []).compactMap(
                            \.stringValue
                        ).joined(separator: " ")
                    }
                    parent = p.parent
                }
                let described = (node.attribute(forName: "aria-describedby")?.stringValue ?? "")
                    .split(separator: " ").compactMap { ids[String($0)]?.stringValue }.joined(
                        separator: " ")
                let type =
                    node.name == "select"
                    ? "select"
                    : node.name == "button"
                        ? node.attribute(forName: "type")?.stringValue ?? "submit"
                        : node.attribute(forName: "type")?.stringValue ?? "text"
                return HTMLField(
                    node: node,
                    descriptor: [
                        "name": node.attribute(forName: "name")?.stringValue ?? "", "id": id,
                        "type": type.lowercased(),
                        "label":
                            (labels + [
                                wrapping, node.name == "button" ? node.stringValue ?? "" : "",
                            ]).joined(separator: " "),
                        "placeholder": node.attribute(forName: "placeholder")?.stringValue ?? "",
                        "ariaLabel": node.attribute(forName: "aria-label")?.stringValue ?? "",
                        "autocomplete": node.attribute(forName: "autocomplete")?.stringValue ?? "",
                        "description": String(described.prefix(480)),
                        "fieldset": String(legend.prefix(180)),
                    ])
            }
            return HTMLForm(node: form, fields: fields)
        }
    }
    var visible: String {
        guard let root = document?.rootElement() else { return "" }
        func text(_ node: XMLNode) -> String {
            if let e = node as? XMLElement,
                ["script", "style"].contains(e.name ?? "") || e.attribute(forName: "hidden") != nil
                    || e.attribute(forName: "aria-hidden")?.stringValue == "true"
            {
                return ""
            }
            if node.kind == .text { return node.stringValue ?? "" }
            return (node.children ?? []).map(text).joined(separator: " ")
        }
        return String(text(root).prefix(12000))
    }
    var links: [(String, String)] {
        ((try? document?.nodes(forXPath: "//a[@href]")) ?? []).compactMap { n in
            guard let e = n as? XMLElement, let href = e.attribute(forName: "href")?.stringValue
            else { return nil }
            let imageText = ((try? e.nodes(forXPath: ".//img")) ?? []).compactMap {
                ($0 as? XMLElement)?.attribute(forName: "alt")?.stringValue
            }.joined(separator: " ")
            return (
                [
                    e.stringValue ?? "", e.attribute(forName: "title")?.stringValue ?? "",
                    e.attribute(forName: "aria-label")?.stringValue ?? "", imageText,
                ].joined(separator: " "), href
            )
        }
    }
    var errors: String {
        ((try? document?.nodes(
            forXPath: "//*[@role='alert' or contains(@class,'error') or @aria-invalid='true']"))
            ?? []).compactMap(\.stringValue).joined(separator: " ")
    }
}
struct PortalPolicyError: Error { let reason: String }
// Interpret an option's visible answer before its opaque server value. The
// question's polarity applies only to bare boolean answers, never to a full
// marketing statement such as “Receive offers” or “Do not send marketing”.
private func marketingChoiceDeclines(text: String, value: String, optOut: Bool, rules: PortalRules) -> Bool {
    let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let consent = rules.consent(label)
    if consent.hasPrefix("marketing") { return consent == "marketing_opt_out" }
    if matches("^(no thanks|decline|unsubscribe|opt[ _-]*out)$", label) { return true }
    let answer = label.isEmpty ? value : label
    return matches(optOut ? "^(yes|true|1)$" : "^(no|false|0)$", answer)
}
func fill(
    _ form: HTMLForm, identity: PortalIdentity, rules: PortalRules, profile: [String: Any] = [:]
) throws -> [(String, String)] {
    var result: [(String, String)] = []
    let submits = form.fields.filter {
        $0.type == "submit" && !$0.disabled
            && !rules.social($0.wording + " " + $0.value, destination: form.action)
    }
    func submitScore(_ f: HTMLField) -> Int {
        let text = f.wording + " " + f.value
        if rules.consent(text) == "marketing_opt_in" { return -100 }
        if rules.consent(text) == "marketing_opt_out" { return 10 }
        if matches("back|cancel|previous|decline", text) { return -10 }
        return matches("connect|continue|get online|accept|submit", text) ? 5 : 0
    }
    let selectedSubmit = submits.filter { submitScore($0) >= 0 }.max {
        submitScore($0) < submitScore($1)
    }
    var radioNames = Set<String>()
    let splitPhone = form.fields.contains {
        rules.intent($0.descriptor, profile: profile) == "phone_country_code"
    }
    for f in form.fields where !f.disabled && !f.name.isEmpty {
        if ["reset", "button", "file", "image"].contains(f.type) { continue }
        if f.type == "hidden" || f.node.attribute(forName: "readonly") != nil {
            result.append((f.name, f.value))
            continue
        }
        if f.type == "submit" {
            if selectedSubmit?.node === f.node {
                result.append((f.name, f.value.isEmpty ? "Submit" : f.value))
            }
            continue
        }
        if f.type == "radio" {
            if !radioNames.insert(f.name).inserted { continue }
            let group = form.fields.filter {
                $0.type == "radio" && $0.name == f.name && !$0.disabled
            }
            let text = group.map { $0.wording + " " + ($0.descriptor["fieldset"] ?? "") }.joined(separator: " ")
            let desired = rules.intent(f.descriptor).flatMap { persona($0, identity) }
            var selected: HTMLField?
            if rules.consent(text).hasPrefix("marketing") {
                let prompt = group.map {
                    [$0.name, $0.descriptor["fieldset"] ?? "", $0.descriptor["description"] ?? ""]
                        .joined(separator: " ")
                }.joined(separator: " ")
                let optOut = rules.consent(prompt) == "marketing_opt_out"
                let safeChoices = group.filter {
                    marketingChoiceDeclines(
                        text: [$0.descriptor["label"] ?? "", $0.descriptor["ariaLabel"] ?? ""]
                            .joined(separator: " "), value: $0.value, optOut: optOut, rules: rules)
                }
                selected = safeChoices.count == 1 ? safeChoices.first : nil
                if selected == nil && group.contains(where: \.required) {
                    throw PortalPolicyError(reason: "marketing_consent_required")
                }
            } else {
                if let desired, !desired.isEmpty {
                    selected = group.first {
                        canonical($0.value) == canonical(desired)
                            || canonical($0.descriptor["label"] ?? "") == canonical(desired)
                    }
                }
                selected = selected ?? group.first { $0.node.attribute(forName: "checked") != nil }
            }
            if let selected {
                result.append((f.name, selected.value))
            } else if group.contains(where: \.required) {
                throw PortalPolicyError(reason: "unknown_required_field")
            }
            continue
        }
        if f.type == "checkbox" {
            let consent = rules.consent(f.wording)
            if consent == "marketing_opt_in" {
                if f.required { throw PortalPolicyError(reason: "marketing_consent_required") }
                continue
            }
            if consent == "terms" || consent == "marketing_opt_out" {
                result.append((f.name, f.value.isEmpty ? "on" : f.value))
                continue
            }
            if f.required && f.type == "checkbox" {
                throw PortalPolicyError(reason: "unknown_required_field")
            }
            continue
        }
        let selectConsent = rules.consent(f.wording + " " + (f.descriptor["fieldset"] ?? ""))
        if f.type == "select" && selectConsent.hasPrefix("marketing") {
            let safeChoices = f.options.filter {
                !$0.disabled && !$0.value.isEmpty
                    && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !matches("^(choose|select|please select|--)", $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    && marketingChoiceDeclines(text: $0.text, value: $0.value,
                        optOut: selectConsent == "marketing_opt_out", rules: rules)
            }
            if safeChoices.count == 1, let decline = safeChoices.first {
                result.append((f.name, decline.value))
            } else if f.required {
                throw PortalPolicyError(reason: "marketing_consent_required")
            }
            continue
        }
        let intent =
            rules.intent(f.descriptor, profile: profile)
            ?? (f.type == "date" ? "date_of_birth" : nil)
        if !f.required
            && ["verification_code", "account_password", "issued_identifier"].contains(intent ?? "")
        {
            continue
        }
        if intent == "verification_code" {
            throw PortalPolicyError(reason: "verification_code_required")
        }
        if intent == "issued_identifier" {
            throw PortalPolicyError(
                reason: rules.policy("unknownIdentifier", f.wording)
                    ? "unknown_required_field" : "voucher_or_venue_credential_required")
        }
        if intent == "account_password" || intent == "username" && f.required {
            throw PortalPolicyError(reason: "account_credentials_required")
        }
        if intent == "password",
            !matches(
                "register|registration|sign.?up|create|new.password",
                form.action + " " + (form.node.stringValue ?? "") + " "
                    + (f.descriptor["autocomplete"] ?? ""))
        {
            throw PortalPolicyError(reason: "account_credentials_required")
        }
        var value = intent.flatMap { persona($0, identity) }
        if intent == "phone", let v = value {
            let digits = v.filter(\.isNumber)
            let uk = ["uk", "gb", "gbr", "unitedkingdom", "greatbritain"].contains(
                canonical(persona("country", identity) ?? ""))
            let local =
                digits.hasPrefix("0044")
                ? String(digits.dropFirst(4))
                : digits.hasPrefix("44") && digits.count > 10
                    ? String(digits.dropFirst(2))
                    : digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
            let international =
                uk ? "+44" + local : e164(v, country: persona("country", identity) ?? "")
            let preferred =
                splitPhone && uk
                ? local : matches("international|e.?164|\\+44", f.wording) ? international : v
            let candidates =
                uk
                ? [preferred, v, "0" + local, international, "0044" + local, local]
                : [v, v.filter { !" ().-".contains($0) }]
            value = candidates.first { fieldFits($0, f) }
            if value == nil { throw PortalPolicyError(reason: "validation_exhausted") }
        }
        if intent == "date_of_birth", let v = value { value = formattedDOB(v, hint: f.wording) }
        if ["postcode", "date_of_birth"].contains(intent ?? ""), let v = value, !fieldFits(v, f) {
            value = variants(intent ?? "", persona(intent ?? "", identity) ?? v).first {
                fieldFits($0, f)
            }
        }
        if f.type == "select" {
            value = selectChoice(f, desired: value, intent: intent)

        }
        if value == nil && f.type != "select" { value = f.value.isEmpty ? nil : f.value }
        if let value {
            if f.required && !fieldFits(value, f) {
                throw PortalPolicyError(reason: "validation_exhausted")
            }
            result.append((f.name, value))
        } else if f.required {
            throw PortalPolicyError(reason: "unknown_required_field")
        }
    }
    return result
}
func boundary(_ page: HTMLPage, html: String, form: HTMLForm?, rules: PortalRules) -> String? {
    if matches(
        "class\\s*=\\s*['\"][^'\"]*(?:g-recaptcha|h-captcha)|data-sitekey|cf-turnstile", html)
        || matches("(?:complete|solve|enter).{0,30}captcha|prove.{0,20}human", page.visible)
    {
        return "captcha_required"
    }
    let fields = form?.fields.filter { !$0.disabled } ?? []
    let ordinary = fields.contains {
        ["email", "first_name", "last_name", "full_name", "phone"].contains(
            rules.intent($0.descriptor) ?? "")
    }
    let searchable =
        ordinary
        ? fields.filter(\.required).map(\.wording).joined(separator: " ")
        : page.visible + " " + fields.map(\.wording).joined(separator: " ")
    if fields.contains(where: {
        (!ordinary || $0.required) && ($0.descriptor["autocomplete"] ?? "").hasPrefix("cc-")
    }) {
        return "payment_required"
    }
    if matches(
        "one.time.code|verification.code|\\botp\\b|two.factor|authenticator|passcode|(?:enter|sent).{0,30}\\bcode\\b",
        searchable)
    {
        if matches("two.factor|authenticator|\\b2fa\\b", page.visible) { return "two_factor" }
        return matches(#"\bsms\b|text message|sent.{0,40}(?:your )?phone"#, page.visible)
            ? "sms_verification" : "verification_code_required"
    }
    if matches("voucher|access.code|room.number|booking.reference|ticket.number", searchable) {
        return "voucher_or_venue_credential_required"
    }
    if matches("sponsor.{0,20}approv|person[ _-]*being[ _-]*visited|host[ _-]*email", searchable) {
        return "sponsor_approval_required"
    }
    if matches("passport|national.id|government.id", searchable) {
        return "government_identity_required"
    }
    let meaningful = fields.filter {
        !["hidden", "submit", "checkbox", "radio", "select"].contains($0.type)
            && $0.node.attribute(forName: "readonly") == nil
    }
    if meaningful.count == 1, let field = meaningful.first, field.required,
        rules.intent(field.descriptor) == nil, matches("\\bcode\\b", field.wording)
    {
        let maximum = Int(field.node.attribute(forName: "maxlength")?.stringValue ?? "")
        if let maximum, (4...8).contains(maximum) { return "verification_code_required" }
        if matches("\\{[4-8]\\}", field.node.attribute(forName: "pattern")?.stringValue ?? "") {
            return "verification_code_required"
        }
    }
    if fields.contains(where: {
        $0.required && rules.intent($0.descriptor) == nil
            && matches(#"\b(?:identification|identifier|reference)\b"#, $0.wording)
    }) {
        return "unknown_required_field"
    }
    if form == nil && matches("e.?mail|inbox", page.visible)
        && matches("verif|confirm|activat", page.visible)
        && matches("link|click|sent", page.visible)
    {
        return "email_verification"
    }
    return nil
}

func fieldFits(_ value: String, _ field: HTMLField) -> Bool {
    if let max = Int(field.node.attribute(forName: "maxlength")?.stringValue ?? ""),
        value.count > max
    {
        return false
    }
    if let min = Int(field.node.attribute(forName: "minlength")?.stringValue ?? ""),
        value.count < min
    {
        return false
    }
    if let pattern = field.node.attribute(forName: "pattern")?.stringValue, !pattern.isEmpty,
        !matches("^(?:" + pattern + ")$", value)
    {
        return false
    }
    if field.type == "date" {
        if let min = field.node.attribute(forName: "min")?.stringValue, value < min { return false }
        if let max = field.node.attribute(forName: "max")?.stringValue, value > max { return false }
    }
    if ["number", "range"].contains(field.type), let n = Double(value) {
        if let min = Double(field.node.attribute(forName: "min")?.stringValue ?? ""), n < min {
            return false
        }
        if let max = Double(field.node.attribute(forName: "max")?.stringValue ?? ""), n > max {
            return false
        }
    }
    return true
}
func formattedDOB(_ value: String, hint: String) -> String {
    let p = value.split(separator: "-")
    guard p.count == 3 else { return value }
    for separator in ["/", ".", "-"] {
        if hint.lowercased().contains("dd" + separator + "mm" + separator + "yyyy") {
            return String(p[2]) + separator + p[1] + separator + p[0]
        }
        if hint.lowercased().contains("mm" + separator + "dd" + separator + "yyyy") {
            return String(p[1]) + separator + p[2] + separator + p[0]
        }
    }
    return value
}
func selectChoice(_ field: HTMLField, desired: String?, intent: String?) -> String? {
    let options = field.options.filter { !$0.disabled }
    if let desired, let n = Int(desired),
        ["birth_day", "birth_month", "birth_year"].contains(intent ?? "")
    {
        var labels = [String(n), String(format: "%02d", n)]
        if intent == "birth_month", (1...12).contains(n) {
            let months = [
                "january", "february", "march", "april", "may", "june", "july", "august",
                "september", "october", "november", "december",
            ]
            labels += [months[n - 1], String(months[n - 1].prefix(3))]
        }
        if let option = options.first(where: {
            labels.contains($0.text.trimmingCharacters(in: .whitespaces).lowercased())
        }) {
            return option.value
        }
        if intent == "birth_month" { return nil }
    }
    if intent == "phone_country_code", let desired {
        let digits = desired.filter(\.isNumber)
        if let option = options.first(where: {
            $0.value.filter(\.isNumber) == digits
                || matches("(?:^|\\D)" + digits + "(?:\\D|$)", $0.text)
        }) {
            return option.value
        }
    }
    var keys = [canonical(desired ?? "")]
    if intent == "country" { keys += ["unitedkingdom", "uk", "gb", "gbr"] }
    if intent == "gender" {
        keys += ["prefernottosay", "prefernottodisclose", "decline", "unspecified", "other"]
    }
    if intent == "title" { keys += ["mx", "other"] }
    for key in keys where !key.isEmpty {
        if let option = options.first(where: {
            canonical($0.value) == key || canonical($0.text) == key
        }) {
            return option.value
        }
    }
    if intent == "age", let age = Int(desired ?? "") {
        for option in options {
            let text = option.value + " " + option.text
            let regex = try? NSRegularExpression(pattern: "(\\d{1,3})\\s*(?:-|–|to)\\s*(\\d{1,3})")
            if let m = regex?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                let low = Int((text as NSString).substring(with: m.range(at: 1))),
                let high = Int((text as NSString).substring(with: m.range(at: 2))),
                low <= age && age <= high
            {
                return option.value
            }
        }
    }
    if let option = options.first(where: \.selected) { return option.value }
    if desired == nil && !field.required { return nil }
    return nil
}

import CryptoKit
import Foundation

/// A bounded schema description for export. Raw values, labels, HTML, headers,
/// passwords, cookies and page titles are deliberately excluded.
public enum PortalStructureReporter {
    public static func describe(body: String, contentType: String, resources: URL) -> [String: Any]
    {
        let bounded = String(body.prefix(2_097_152))
        let rules = PortalRules(resources: resources)
        let page = HTMLPage(bounded)
        let knownNames = Set((rules.schema["names"] as? [String: String] ?? [:]).keys).union([
            "csrf", "csrfmiddlewaretoken", "csrftoken", "token", "mac", "macaddress", "terms",
            "termsaccepted", "acceptterms", "tnc", "marketing", "marketingoptin", "marketingoptout",
            "submit", "connect", "continue", "grant", "loginmethod", "useremail",
            "phonenumberprefix", "formtype", "sessionvalidation", "expirydate", "locationid",
            "btmarketingconsent", "partnermarketingconsent", "wsuuid", "authmethod",
            "authmethodidentifier", "2stepmarketingchosen", "dobd", "dobm", "doby",
        ])
        func name(_ raw: String) -> String {
            if raw.utf8.count <= 120 && knownNames.contains(canonical(raw))
                && matches("^[A-Za-z][A-Za-z0-9_.\\[\\]-]{0,119}$", raw)
            {
                return raw
            }
            return "redacted-field-" + digest(raw).prefix(12)
        }
        let allowedTypes: Set<String> = [
            "text", "email", "phone", "tel", "password", "hidden", "number", "date", "time",
            "datetime-local", "month", "week", "url", "search", "checkbox", "radio", "select",
            "textarea", "submit", "button", "reset", "file", "image", "range", "color",
        ]
        let auto = Set((rules.schema["autocomplete"] as? [String: String] ?? [:]).keys).union([
            "on", "off",
        ])
        let forms: [[String: Any]] = page.forms.prefix(20).map { form in
            let fields: [[String: Any]] = form.fields.filter {
                !$0.name.isEmpty && $0.node.name != "button"
            }.prefix(100).map { field in
                let autocomplete = (field.descriptor["autocomplete"] ?? "").split(separator: " ")
                    .map(String.init).filter { auto.contains($0.lowercased()) }.joined(
                        separator: " ")
                let inputmode = field.node.attribute(forName: "inputmode")?.stringValue ?? ""
                let maximum = Int(field.node.attribute(forName: "maxlength")?.stringValue ?? "")
                return [
                    "name": name(field.name),
                    "type": allowedTypes.contains(field.type) ? field.type : "unknown",
                    "required": field.required,
                    "intent": rules.intent(field.descriptor) as Any? ?? NSNull(),
                    "autocomplete": autocomplete.isEmpty ? NSNull() : autocomplete as Any,
                    "inputmode": [
                        "none", "text", "decimal", "numeric", "tel", "search", "email", "url",
                    ].contains(inputmode) ? inputmode as Any : NSNull(),
                    "maxlength": maximum.flatMap { (0...10000).contains($0) ? $0 : nil } as Any?
                        ?? NSNull(),
                    "has_pattern": !(field.node.attribute(forName: "pattern")?.stringValue ?? "")
                        .isEmpty,
                ]
            }
            return [
                "action_path": actionPath(form.action) as Any? ?? NSNull(),
                "method": ["GET", "POST"].contains(form.method)
                    ? form.method.lowercased() : "unknown", "fields": fields,
            ]
        }
        var hints: [String] = []
        if matches("window\\.journeyData|wifi\\.wireless-social\\.com", bounded) {
            hints.append("wireless_social")
        }
        if matches("base_grant_url|network-auth\\.com", bounded) {
            hints.append("meraki_external_splash")
        }
        var responseKeys: [String] = []
        var declared: [[String: Any]] = []
        var validation: [String] = []
        let knownKeys: Set<String> = [
            "success", "ok", "error", "errors", "errorCode", "validationErrors",
            "validationFieldErrors", "wifiUser", "stdFields", "opFields", "spFields",
            "operatorFields", "sponsorFields", "journeyMetaData", "venue", "journeyLogic", "url",
            "redirectUrl", "invEm", "opProcessed", "spProcessed",
        ]
        if contentType.lowercased().hasPrefix("application/json")
            || bounded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        {
            if let value = object(bounded) {
                responseKeys = value.keys.sorted().prefix(100).map {
                    knownKeys.contains($0) ? $0 : "redacted-key-" + digest($0).prefix(12)
                }
                declared = declaredFields(value, rules: rules, safeName: name, types: allowedTypes)
                validation = Array(Set(validationNames(value).prefix(100).map(name))).sorted()
            }
        }
        if let journey = extractJourney(bounded) {
            declared = declaredFields(journey, rules: rules, safeName: name, types: allowedTypes)
        }
        let fingerprint: [String: Any] = ["forms": forms, "provider_hints": hints]
        let template =
            (try? JSONSerialization.data(
                withJSONObject: fingerprint, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return [
            "forms": forms, "provider_hints": hints, "response_keys": responseKeys,
            "declared_fields": declared, "validation_fields": validation,
            "template_sha256": SHA256.hash(data: template).map { String(format: "%02x", $0) }
                .joined(),
        ]
    }
    private static func declaredFields(
        _ value: [String: Any], rules: PortalRules, safeName: (String) -> String, types: Set<String>
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for collection in ["stdFields", "opFields", "spFields", "operatorFields", "sponsorFields"] {
            for field in (value[collection] as? [[String: Any]] ?? []).prefix(100) {
                guard result.count < 100, let name = field["name"] as? String, !name.isEmpty else {
                    continue
                }
                let type = field["type"] as? String ?? ""
                let descriptor = [
                    "name": name, "type": type, "label": field["label"] as? String ?? "",
                    "placeholder": field["placeholder"] as? String ?? "",
                ]
                result.append([
                    "collection": collection, "name": safeName(name),
                    "type": types.contains(type) ? type as Any : NSNull(),
                    "required": (field["requirement"] as? String)?.lowercased() == "required",
                    "intent": rules.intent(descriptor) as Any? ?? NSNull(),
                ])
            }
        }
        return result
    }
    private static func actionPath(_ action: String) -> String? {
        guard !action.isEmpty else { return nil }
        let path = URLComponents(string: action)?.path ?? ""
        // Paths can embed opaque grant/session identifiers. Preserve only
        // short ordinary route segments that cannot carry contact details.
        guard !path.contains("@"), !matches("[a-f0-9]{16,}|[A-Za-z0-9_-]{24,}|\\b\\d{7,}\\b", path),
            path.count <= 240
        else { return "/redacted" }
        let vocabulary: Set<String> = [
            "guest", "connect", "continue", "register", "registration", "login", "logout", "auth",
            "user", "form", "journey", "profile", "process", "accept", "grant", "splash",
            "redirect", "post-auth", "meraki", "mr", "check", "wifi", "wi-fi", "terms", "portal",
            "home", "end", "data-set", "cambium", "cn-pilot",
        ]
        let components = path.split(separator: "/").map {
            vocabulary.contains($0.lowercased()) ? String($0) : "redacted"
        }
        return "/" + components.joined(separator: "/")
    }
    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

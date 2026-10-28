import CuppaCore
import Foundation

struct PortalRules: Sendable {
    let schemaData: Data?
    let profilesData: Data?
    let ladderData: Data?
    init(resources: URL) {
        func read(_ name: String) -> Data? {
            for candidate in [
                resources.appendingPathComponent(name),
                resources.appendingPathComponent("wifi-autologin/" + name),
            ] {
                if let data = try? Data(contentsOf: candidate) { return data }
            }
            return nil
        }
        schemaData = read("portal-schema.json")
        profilesData = read("vendor-profiles.json")
        ladderData = read("correction-ladder.json")
    }
    var correctionRounds: Int {
        guard let data = ladderData,
            let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            value["format"] as? Int == 1, let rounds = value["maxCorrectionRounds"] as? Int,
            (0...5).contains(rounds)
        else { return 3 }
        return rounds
    }
    var schema: [String: Any] {
        schemaData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    func profile(_ url: URL) -> [String: Any] {
        let profiles =
            profilesData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?[
                "profiles"] as? [[String: Any]] ?? []
        return profiles.first { p in
            (p["hosts"] as? [String] ?? []).contains { hostMatches(url.host ?? "", $0) }
        } ?? ["id": "generic"]
    }
    func consent(_ text: String) -> String {
        let c = schema["consent"] as? [String: String] ?? [:]
        if matches(
            c["marketing"] ?? "marketing|offers?|newsletter|promo|communications|contact me", text)
            || matches("opt[ _-]*out", text)
        {
            return matches(c["optOut"] ?? "opt[ _-]*out|do not|don't|unsubscribe|decline", text)
                ? "marketing_opt_out" : "marketing_opt_in"
        }
        return matches(c["terms"] ?? "terms|conditions|privacy|agree|accept|tnc", text)
            ? "terms" : "unknown"
    }
    func policy(_ name: String, _ text: String) -> Bool {
        guard let pattern = (schema["policy"] as? [String: String])?[name] else { return false }
        return matches(pattern, text)
    }
    func social(_ label: String, destination: String = "") -> Bool {
        if policy("socialAction", label) { return true }
        var decoded = destination
        for _ in 0..<3 {
            if policy("socialDestination", decoded) { return true }
            decoded = decoded.removingPercentEncoding ?? decoded
        }
        return false
    }
    func intent(_ d: [String: String], profile: [String: Any] = [:]) -> String? {
        let text = ["name", "id", "label", "placeholder", "ariaLabel", "description"].map {
            d[$0] ?? ""
        }.joined(separator: " ")
        if policy("issuedIdentifier", text) { return "issued_identifier" }
        let tokens = (d["autocomplete"] ?? "").lowercased().split(separator: " ")
        let auto = schema["autocomplete"] as? [String: String] ?? [:]
        let autocomplete = tokens.reversed().compactMap { auto[String($0)] }.first
        let type = d["type"] ?? "text"
        if !["verification_code", "account_password", "phone_country_code"].contains(
            autocomplete ?? ""), let result = (schema["types"] as? [String: String])?[type]
        {
            return result
        }
        if let autocomplete { return autocomplete }
        let countryIdentifiers = (d["name"] ?? "") + " " + (d["id"] ?? "")
        let separated = countryIdentifiers.replacingOccurrences(
            of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression
        ).replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
        let patterns = schema["patterns"] as? [[String: String]] ?? []
        var intents = Set(
            patterns.filter {
                matches(
                    $0["pattern"] ?? "(?!)",
                    text + ($0["intent"] == "country" ? " " + separated : ""))
            }.compactMap { $0["intent"] })
        let group = d["fieldset"] ?? ""
        if patterns.contains(where: {
            $0["intent"] == "date_of_birth" && matches($0["pattern"] ?? "(?!)", group)
        }) {
            let parts = ["day", "month", "year"].filter { matches("\\b" + $0 + "\\b", text) }
            if parts.count == 1 { return "birth_" + parts[0] }
        }
        if intents.contains("first_name") && intents.contains("last_name")
            || matches(schema["compoundName"] as? String ?? "(?!)", text)
        {
            intents.remove("first_name")
            intents.remove("last_name")
            intents.insert("full_name")
        } else if !intents.isDisjoint(with: ["first_name", "last_name"]) {
            intents.remove("full_name")
        }
        for (specific, general) in [
            ("email", "address_line_1"), ("address_line_2", "address_line_1"),
            ("occupation", "title"), ("postcode", "address_line_1"),
            ("phone_country_code", "phone"), ("phone_country_code", "country"),
        ] {
            if intents.contains(specific) { intents.remove(general) }
        }
        if !intents.isDisjoint(with: ["birth_day", "birth_month", "birth_year"]) {
            intents.remove("date_of_birth")
        }
        if let ambiguities = schema["descriptionAmbiguity"] as? [String: [String: String]] {
            for (intent, ambiguity) in ambiguities where intents.contains(intent) {
                let primary = ["name", "id", "label", "placeholder", "ariaLabel"].map {
                    d[$0] ?? ""
                }.joined(separator: " ")
                if matches(ambiguity["wording"] ?? "(?!)", d["description"] ?? "")
                    && !matches(ambiguity["wording"] ?? "(?!)", primary)
                    && !matches(ambiguity["specific"] ?? "(?!)", text)
                {
                    intents.remove(intent)
                }
            }
        }
        let names = schema["names"] as? [String: String] ?? [:]
        for key in ["name", "id"] {
            let name = canonical(d[key] ?? "")
            if let alias = (profile["fieldAliases"] as? [String: String])?[name] { return alias }
            if let intent = names[name] {
                if numericConflict(type, intent) || intents.count > 1
                    || (!intents.isEmpty && !intents.contains(intent) && intents != ["full_name"])
                {
                    return nil
                }
                return intent
            }
        }
        guard intents.count == 1, let result = intents.first, !numericConflict(type, result) else {
            return nil
        }
        return result
    }
    func numericConflict(_ type: String, _ intent: String) -> Bool {
        type == "number"
            && ((schema["reasoning"] as? [String: Any])?["numericTextIntents"] as? [String] ?? [])
                .contains(intent)
    }
}
func matches(_ pattern: String, _ text: String) -> Bool {
    text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}
func canonical(_ text: String) -> String {
    text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
}
func hostMatches(_ host: String, _ domain: String) -> Bool {
    host.lowercased() == domain || host.lowercased().hasSuffix("." + domain)
}
func persona(_ intent: String, _ identity: PortalIdentity) -> String? {
    let mapping = [
        "email": "FAKE_EMAIL", "first_name": "FAKE_FIRST_NAME", "last_name": "FAKE_LAST_NAME",
        "phone": "FAKE_PHONE", "postcode": "FAKE_POSTCODE", "date_of_birth": "FAKE_DOB",
        "address_line_1": "FAKE_ADDRESS_LINE_1", "address_line_2": "FAKE_ADDRESS_LINE_2",
        "city": "FAKE_CITY", "county": "FAKE_COUNTY", "country": "FAKE_COUNTRY",
        "title": "FAKE_TITLE", "gender": "FAKE_GENDER", "company": "FAKE_COMPANY",
        "occupation": "FAKE_OCCUPATION", "reason_for_visit": "FAKE_REASON_FOR_VISIT",
        "password": "SIGNUP_PASSWORD",
    ]
    if intent == "full_name" { return identity.fullName }
    if intent == "username" { return identity.username }
    if intent == "customer_status" { return "No" }
    if intent == "phone_country_code" {
        return ["uk", "gb", "unitedkingdom"].contains(
            canonical(
                identity["FAKE_COUNTRY"].isEmpty ? "United Kingdom" : identity["FAKE_COUNTRY"]))
            ? "+44" : nil
    }
    let parts = identity.dateOfBirth.split(separator: "-").map(String.init)
    if parts.count == 3 {
        if intent == "birth_day" { return parts[2] }
        if intent == "birth_month" { return parts[1] }
        if intent == "birth_year" { return parts[0] }
        if intent == "age", let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2])
        {
            let now = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            return String(
                (now.year ?? year) - year
                    - (((now.month ?? 1), (now.day ?? 1)) < (month, day) ? 1 : 0))
        }
    }
    guard let key = mapping[intent] else { return nil }
    let defaults = [
        "FAKE_TITLE": "Mx", "FAKE_ADDRESS_LINE_1": "1 Example Street", "FAKE_ADDRESS_LINE_2": "",
        "FAKE_CITY": "London", "FAKE_COUNTY": "Greater London", "FAKE_COUNTRY": "United Kingdom",
        "FAKE_GENDER": "Prefer not to say", "FAKE_COMPANY": "Independent",
        "FAKE_OCCUPATION": "Other", "FAKE_REASON_FOR_VISIT": "Guest Wi-Fi access",
    ]
    let value = identity.values[key] ?? defaults[key] ?? ""
    return value.isEmpty ? nil : value
}
func e164(_ phone: String, country: String = "United Kingdom") -> String {
    let digits = phone.filter(\.isNumber)
    if phone.hasPrefix("+") { return "+" + digits }
    if digits.hasPrefix("00") { return "+" + digits.dropFirst(2) }
    guard ["uk", "gb", "gbr", "unitedkingdom", "greatbritain"].contains(canonical(country)) else {
        return phone
    }
    if digits.hasPrefix("44") { return "+" + digits }
    if digits.hasPrefix("0") { return "+44" + digits.dropFirst() }
    return phone
}
func variants(_ intent: String, _ original: String) -> [String] {
    var values: [String] = []
    switch intent {
    case "phone":
        let digits = original.filter(\.isNumber)
        var national = digits
        if national.hasPrefix("0044") {
            national = String(national.dropFirst(4))
        } else if national.hasPrefix("44") && national.count > 10 {
            national = String(national.dropFirst(2))
        } else if national.hasPrefix("0") {
            national = String(national.dropFirst())
        }
        guard !national.isEmpty else { return [] }
        values = [
            "0" + national, "+44" + national, "0044" + national,
            original.filter { !" ().-".contains($0) },
        ]
    case "postcode":
        let compact = original.uppercased().filter { !$0.isWhitespace }
        let spaced =
            compact.count >= 5 ? String(compact.dropLast(3)) + " " + compact.suffix(3) : compact
        values = [spaced, compact, original.uppercased(), original.filter { !$0.isWhitespace }]
    case "date_of_birth":
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.isLenient = false
        var date: Date?
        for pattern in ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MM-yyyy"] {
            parser.dateFormat = pattern
            if let parsed = parser.date(from: original) {
                date = parsed
                break
            }
        }
        guard let date else { return [] }
        values = ["yyyy-MM-dd", "dd/MM/yyyy", "MM/dd/yyyy", "dd-MM-yyyy"].map {
            parser.dateFormat = $0
            return parser.string(from: date)
        }
    default: return []
    }
    var seen = Set<String>()
    return values.filter { !$0.isEmpty && $0 != original && seen.insert($0).inserted }
}

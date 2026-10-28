import CuppaCore
import Foundation

/// Native static portal actions. A submitted result always requires independent
/// connectivity verification by the engine; this module never reports ONLINE.
public struct PortalWorkflow: PortalHandling {
    let client: any HTTPClient
    let resources: URL
    let dataDirectory: URL
    public init(client: any HTTPClient, resources: URL, dataDirectory: URL) {
        self.client = client
        self.resources = resources
        self.dataDirectory = dataDirectory
    }
    public func login(url: URL, identity: PortalIdentity, network: NetworkSnapshot) async
        -> PortalAttempt
    {
        await PortalSession(
            client: client, rules: PortalRules(resources: resources), identity: identity,
            entry: url, network: network, dataDirectory: dataDirectory
        ).run()
    }
}

actor PortalSession {
    let client: any HTTPClient
    let rules: PortalRules
    let identity: PortalIdentity
    let entry: URL
    let network: NetworkSnapshot
    let dataDirectory: URL
    let deadline: Date
    var hops: [PortalHop] = []
    var actions = 0
    var provider = "generic"
    var venue: String?
    var corrections: [String: [String]] = [:]
    var signature: String?
    var steps: [PortalStep] = []
    var currentURL: URL
    var submitted = false
    init(
        client: any HTTPClient, rules: PortalRules, identity: PortalIdentity, entry: URL,
        network: NetworkSnapshot, dataDirectory: URL, deadline: Date = Date().addingTimeInterval(20)
    ) {
        self.client = client
        self.rules = rules
        self.deadline = deadline
        self.identity = identity
        self.entry = entry
        self.network = network
        self.dataDirectory = dataDirectory
        currentURL = entry
    }
    func result(_ outcome: PortalAttempt.Outcome, _ reason: String = "") -> PortalAttempt {
        PortalAttempt(
            outcome: outcome, reason: reason, portalURL: currentURL, provider: provider,
            venue: venue,
            hops: hops, actions: actions, pendingSubmission: submitted, corrections: corrections,
            signature: signature,
            steps: Array(
                (steps + [
                    PortalStep(
                        phase: "portal",
                        title: outcome == .submitted
                            ? (actions > 0
                                ? "Portal action awaiting connectivity verification"
                                : "Portal page awaiting connectivity verification")
                            : outcome == .browser
                                ? "Continuing in the browser" : "Portal workflow stopped",
                        detail: reason,
                        status: outcome == .failed || outcome == .unsupported ? "blocked" : "ok")
                ]).suffix(32)))
    }
    func run() async -> PortalAttempt {
        do {
            let landing = try await request(entry)
            currentURL = landing.url
            guard (200..<300).contains(landing.status), !landing.truncated else {
                return result(.unsupported, "portal_page_unavailable")
            }
            let host = landing.url.host?.lowercased() ?? ""
            if host == "free-wifi.nandos.co.uk" {
                provider = "nandos"
                venue = "Nando's"
                try await nandos(landing)
                return result(.submitted)
            }
            if isBTProviderHost(host) {
                provider = "bt"
                try await bt(landing)
                return result(.submitted)
            }
            if hostMatches(host, "fydelia.com") {
                provider = "fydelia"
                try await fydelia(landing)
                return result(.submitted)
            }
            if PortalRegistry().resolve(
                domain: host, ssid: network.ssid, gatewayMAC: network.gatewayMAC
            ).provider == "wireless-social" {
                provider = "wireless-social"
                try await wireless(landing)
                return result(.submitted)
            }
            return try await generic(landing)
        } catch let error as PortalPolicyError {
            if error.reason == "portal_request_budget_exhausted" {
                return result(.browser, "action_budget_exhausted")
            }
            let unsupported = [
                "captcha_required", "verification_code_required",
                "voucher_or_venue_credential_required", "sponsor_approval_required",
                "government_identity_required", "marketing_consent_required",
                "social_login_required", "account_credentials_required", "unknown_required_field",
                "payment_required", "email_verification", "sms_verification", "two_factor",
                "persona_phone_rejected", "privacy_email_required", "validation_exhausted",
            ]
            return result(
                unsupported.contains(error.reason)
                    || error.reason.hasPrefix("wireless_social_required_field_unsupported:")
                    ? .unsupported : .failed, error.reason)
        } catch is CancellationError { return result(.failed, "attempt_cancelled") } catch let error
            as URLError
        {
            return result(
                .failed,
                [.cannotFindHost, .dnsLookupFailed].contains(error.code)
                    ? "portal_dns_unavailable" : "portal_transport_unavailable")
        } catch { return result(.failed, "portal_transport_unavailable") }
    }
    func safeURL(_ target: URL, from: URL? = nil) -> Bool {
        guard ["http", "https"].contains(target.scheme ?? ""),
            let rawHost = target.host?.lowercased(),
            target.user == nil, target.password == nil
        else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let from, from.scheme == "https", target.scheme == "http" { return false }
        if let from, target.host != from.host, isLocalHost(host) { return false }
        if ["localhost", "localhost.localdomain", "ip6-localhost", "::1", "0.0.0.0"].contains(host)
            || host.hasPrefix("127.") || host.hasSuffix(".localhost")
        {
            return false
        }
        return true
    }
    func sameOrigin(_ target: URL, _ source: URL) -> Bool {
        target.scheme == source.scheme && target.host?.lowercased() == source.host?.lowercased()
            && (target.port ?? (target.scheme == "https" ? 443 : 80))
                == (source.port ?? (source.scheme == "https" ? 443 : 80))
            && target.user == nil && target.password == nil
    }
    func resolve(_ value: String, base: URL) throws -> URL {
        guard
            let url = PortalRequestURL.url(
                value.isEmpty ? base.absoluteString : value, relativeTo: base)?
                .absoluteURL, safeURL(url, from: base)
        else { throw PortalPolicyError(reason: "unsafe_portal_destination") }
        return url
    }
    func request(
        _ url: URL, method: String = "GET", fields: [(String, String)] = [],
        headers: [String: String] = [:]
    ) async throws -> HTTPResponse {
        var target = url
        var verb = method
        var body = fields.isEmpty && verb == "GET" ? nil : encoded(fields).data(using: .utf8)
        var requestHeaders = headers
        if verb == "GET", !fields.isEmpty {
            var c = URLComponents(url: target, resolvingAgainstBaseURL: false)!
            c.percentEncodedQuery = [c.percentEncodedQuery, encoded(fields)].compactMap { $0 }
                .filter { !$0.isEmpty }.joined(separator: "&")
            target = c.url!
            body = nil
        }
        if verb == "POST" { requestHeaders["Content-Type"] = "application/x-www-form-urlencoded" }
        for _ in 0..<6 {
            try Task.checkCancellation()
            guard deadline.timeIntervalSinceNow > 0 else {
                throw PortalPolicyError(reason: "portal_attempt_deadline_exceeded")
            }
            guard safeURL(target), hops.count < 12 else {
                throw PortalPolicyError(reason: "portal_request_budget_exhausted")
            }
            let req = HTTPRequest(
                url: target, method: verb, headers: requestHeaders, body: body,
                timeout: min(10, deadline.timeIntervalSinceNow), followRedirects: false)
            let beforeHopCount = hops.count
            do {
                let response = try await client.send(req)
                hops.append(PortalHop(request: req, response: response))
                guard !response.truncated else {
                    throw PortalPolicyError(reason: "portal_response_truncated")
                }
                if [301, 302, 303, 307, 308].contains(response.status),
                    let location = response.header("Location")
                {
                    let next = try resolve(location, base: response.url)
                    if rules.social("", destination: next.absoluteString) {
                        throw PortalPolicyError(reason: "social_login_required")
                    }
                    if [307, 308].contains(response.status), verb != "GET",
                        !sameOrigin(next, target)
                    {
                        throw PortalPolicyError(reason: "cross_origin_submission_redirect")
                    }
                    if !sameOrigin(next, target) { requestHeaders = [:] }
                    if response.status == 303
                        || [301, 302].contains(response.status) && verb == "POST"
                    {
                        verb = "GET"
                        body = nil
                        requestHeaders.removeValue(forKey: "Content-Type")
                    }
                    target = next
                    continue
                }
                return response
            } catch {
                if hops.count == beforeHopCount {
                    hops.append(PortalHop(request: req, response: nil))
                }
                throw error
            }
        }
        throw PortalPolicyError(reason: "redirect_limit_reached")
    }
    func post(_ url: URL, _ fields: [(String, String)], headers: [String: String] = [:])
        async throws -> HTTPResponse
    {
        actions += 1
        submitted = true
        recordAction(method: "POST", fields: fields)
        let response = try await request(url, method: "POST", fields: fields, headers: headers)
        guard (200..<400).contains(response.status) else {
            throw PortalPolicyError(reason: "portal_submission_failed")
        }
        return response
    }
    func generic(_ initial: HTTPResponse) async throws -> PortalAttempt {
        var response = initial
        var seen = Set<String>()
        var formHops = 0
        while actions < 8 && hops.count < 16 {
            currentURL = response.url
            let host = response.url.host ?? ""
            if host == "free-wifi.nandos.co.uk" {
                provider = "nandos"
                try await nandos(response)
                return result(.submitted)
            }
            if isBTProviderHost(host) {
                provider = "bt"
                try await bt(response)
                return result(.submitted)
            }
            if hostMatches(host, "fydelia.com") {
                provider = "fydelia"
                try await fydelia(response)
                return result(.submitted)
            }
            if hostMatches(host, "wifi.wireless-social.com") {
                provider = "wireless-social"
                try await wireless(response)
                return result(.submitted)
            }
            let page = HTMLPage(response.text)
            let profile = rules.profile(response.url)
            provider = profile["id"] as? String ?? "generic"
            if matches(
                "page not found|404 not found|service unavailable|temporarily unavailable|internal server error|bad gateway",
                page.visible)
            {
                return result(.unsupported, "portal_page_unavailable")
            }
            let form = page.forms.filter { $0.score(rules: rules) >= 0 }.max {
                $0.score(rules: rules) < $1.score(rules: rules)
            }
            if let form { recordForm(form) }
            if let reason = boundary(page, html: response.text, form: form, rules: rules) {
                if let alternative = freeGuest(page) {
                    let target = try resolve(alternative, base: response.url)
                    guard seen.insert(target.absoluteString).inserted else {
                        return result(.browser, "navigation_loop")
                    }
                    actions += 1
                    recordAction(method: "GET")
                    response = try await request(target)
                    continue
                }
                return result(.unsupported, reason)
            }
            if let form {
                let formSignature = form.signature(rules: rules)
                signature = formSignature
                if learnedBrowser(response.url, signature: signature ?? "") {
                    return result(.browser, "verified_browser_strategy")
                }
                // Keep XML-backed parser values out of actor-isolated boolean
                // autoclosures so this also compiles with Swift 6.1.
                let hasAccountFields = form.fields.contains { field in
                    let password = field.type == "password"
                    let username = rules.intent(field.descriptor) == "username"
                    return password || username
                }
                if explicitCredentials(response.url) && hasAccountFields {
                    return result(.browser, "account_credentials_requires_browser")
                }
                if form.browser(response.text, rules: rules, profile: profile) {
                    return result(.browser, "javascript_form_requires_browser")
                }
                var fields: [(String, String)]
                do {
                    fields = try fill(form, identity: identity, rules: rules, profile: profile)
                } catch let error as PortalPolicyError {
                    if let alternative = freeGuest(page) {
                        let target = try resolve(alternative, base: response.url)
                        guard seen.insert(target.absoluteString).inserted else {
                            return result(.browser, "navigation_loop")
                        }
                        actions += 1
                        recordAction(method: "GET")
                        response = try await request(target)
                        continue
                    }
                    let hasIssuedFields = form.fields.contains {
                        ["issued_identifier", "account_password", "verification_code"].contains(
                            rules.intent($0.descriptor) ?? "")
                    }
                    if error.reason == "unknown_required_field" && !hasIssuedFields {
                        return result(.browser, "requires_browser")
                    }
                    throw error
                }
                var target = try resolve(form.action, base: response.url)
                if rules.social("", destination: target.absoluteString) {
                    return result(.unsupported, "social_login_required")
                }
                guard safeURL(target, from: response.url) else {
                    throw PortalPolicyError(reason: "unsafe_portal_destination")
                }
                if form.method != "GET" && form.method != "POST" {
                    return result(.browser, "unsupported_form_method")
                }
                if formHops >= 8 { return result(.browser, "form_hop_limit_reached") }
                let key = (signature ?? "") + "|" + target.absoluteString
                if seen.contains(key) { return result(.browser, "repeated_form_requires_browser") }
                seen.insert(key)
                formHops += 1
                let previousURL = response.url
                for round in 0...rules.correctionRounds {
                    actions += 1
                    submitted = true
                    recordAction(method: form.method, fields: fields)
                    response = try await request(target, method: form.method, fields: fields)
                    let nextPage = HTMLPage(response.text)
                    if [404, 410, 500, 502, 503, 504].contains(response.status)
                        || matches(
                            "page not found|404 not found|service unavailable|temporarily unavailable|internal server error|bad gateway",
                            nextPage.visible)
                    {
                        return result(.unsupported, "portal_page_unavailable")
                    }
                    // Validation responses (including HTTP 422) can permit format-only
                    // correction. Other non-success responses remain terminal.
                    var hasValidationResponse = false
                    if [400, 422].contains(response.status) {
                        hasValidationResponse = !rejectedFields(response, form: form).isEmpty
                    }
                    guard (200..<400).contains(response.status) || hasValidationResponse else {
                        throw PortalPolicyError(reason: "portal_submission_failed")
                    }
                    // A controller grant may land on a promotion or account page.
                    // Verify connectivity before considering those unrelated forms.
                    if form.method == "GET" && matches("(?:^|/)grant$", target.path) {
                        return result(.submitted)
                    }
                    if let reason = boundary(
                        nextPage, html: response.text, form: nextPage.forms.first, rules: rules)
                    {
                        throw PortalPolicyError(reason: reason)
                    }
                    if let refreshed = nextPage.forms.first(where: {
                        $0.signature(rules: rules) == formSignature
                    }) {
                        target = try resolve(refreshed.action, base: response.url)
                        for hidden in refreshed.fields
                        where hidden.type == "hidden" && !hidden.disabled {
                            fields.removeAll { $0.0 == hidden.name }
                            fields.append((hidden.name, hidden.value))
                        }
                    }
                    let rejected = rejectedFields(response, form: form)
                    if rejected.isEmpty {
                        if jsonRejected(response.text) {
                            throw PortalPolicyError(reason: "portal_submission_rejected")
                        }
                        break
                    }
                    recordCorrection(rejected)
                    var changed = false
                    if round < rules.correctionRounds {
                        for field in rejected {
                            guard let intent = rules.intent(field.descriptor),
                                let index = fields.firstIndex(where: { $0.0 == field.name })
                            else { continue }
                            let original = persona(intent, identity) ?? fields[index].1
                            let candidates = variants(intent, original)
                            let history = corrections[field.name] ?? [fields[index].1]
                            if let next = candidates.first(where: { !history.contains($0) }) {
                                fields[index].1 = next
                                corrections[field.name] = history + [next]
                                changed = true
                            }
                        }
                    }
                    if !changed {
                        if rejected.contains(where: { rules.intent($0.descriptor) == "email" }) {
                            throw PortalPolicyError(reason: "privacy_email_required")
                        }
                        if rejected.contains(where: { rules.intent($0.descriptor) == "phone" }) {
                            rememberPhone()
                            throw PortalPolicyError(reason: "persona_phone_rejected")
                        }
                        throw PortalPolicyError(reason: "validation_exhausted")
                    }
                }
                let nextHost = response.url.host ?? ""
                if hostMatches(nextHost, "wifi.wireless-social.com") {
                    provider = "wireless-social"
                    try await wireless(response)
                    return result(.submitted)
                }
                if nextHost == "portal.btwifi.com" || nextHost == "www.btwifi.com" {
                    provider = "bt"
                    try await bt(response)
                    return result(.submitted)
                }
                if response.url != previousURL && !HTMLPage(response.text).forms.isEmpty {
                    continue
                }
                if HTMLPage(response.text).forms.isEmpty
                    && navigation(HTMLPage(response.text), html: response.text) == nil
                {
                    return result(.submitted)
                }
                continue
            }
            if let navigation = navigation(page, html: response.text) {
                let target = try resolve(navigation, base: response.url)
                if rules.social("", destination: target.absoluteString) {
                    return result(.unsupported, "social_login_required")
                }
                if seen.contains(target.absoluteString) {
                    return result(.browser, "navigation_loop")
                }
                seen.insert(target.absoluteString)
                let isAction = page.links.contains {
                    $0.1 == navigation
                        && matches(
                            "get online|connect|continue|free.{0,20}(?:wifi|wi-fi)|accept", $0.0)
                }
                if isAction {
                    // Script/meta redirects transport the session; only a reviewed
                    // explicit continuation can be counted as a portal action.
                    actions += 1
                    submitted = true
                    recordAction(method: "GET")
                }
                do { response = try await request(target) } catch {
                    if trustedMerakiGrant(landing: response.url, target: target) {
                        return result(.browser, "meraki_grant_transport_ambiguous")
                    }
                    throw error
                }
                guard (200..<400).contains(response.status) else {
                    return result(.failed, "portal_navigation_failed")
                }
                if isAction && matches("(?:^|/)grant$", target.path) { return result(.submitted) }
                if response.url.host == "free-wifi.nandos.co.uk" {
                    provider = "nandos"
                    try await nandos(response)
                    return result(.submitted)
                }
                if hostMatches(response.url.host ?? "", "wifi.wireless-social.com") {
                    provider = "wireless-social"
                    try await wireless(response)
                    return result(.submitted)
                }
                if hostMatches(response.url.host ?? "", "fydelia.com") {
                    provider = "fydelia"
                    try await fydelia(response)
                    return result(.submitted)
                }
                if ["portal.btwifi.com", "www.btwifi.com", "reg.btwifi.com"].contains(
                    response.url.host ?? "")
                {
                    provider = "bt"
                    try await bt(response)
                    return result(.submitted)
                }
                continue
            }
            if submitted { return result(.submitted) }
            if !page.links.isEmpty
                && page.links.allSatisfy({ rules.social($0.0, destination: $0.1) })
            {
                return result(.unsupported, "social_login_required")
            }
            return result(.browser, "no_static_form_found")
        }
        return result(.browser, "action_budget_exhausted")
    }
    func freeGuest(_ page: HTMLPage) -> String? {
        page.links.first {
            !rules.social($0.0, destination: $0.1)
                && matches(
                    "free.{0,20}(?:wifi|wi-fi)|guest.{0,20}(?:wifi|wi-fi|access)|use.{0,20}email",
                    $0.0)
        }?.1
    }
    func navigation(_ page: HTMLPage, html: String) -> String? {
        for (label, url) in page.links
        where !rules.social(label, destination: url)
            && matches(
                "get online|connect|continue|free.{0,20}(?:wifi|wi-fi)|use.{0,20}email|accept",
                label)
        { return url }
        if let meta =
            (try? page.document?.nodes(
                forXPath: "//meta[translate(@http-equiv,'REFSH','refsh')='refresh']"))?.first
            as? XMLElement,
            let content = meta.attribute(forName: "content")?.stringValue,
            let range = content.range(
                of: "url\\s*=\\s*", options: [.regularExpression, .caseInsensitive])
        {
            return String(content[range.upperBound...]).trimmingCharacters(
                in: CharacterSet(charactersIn: " '\""))
        }
        let pattern =
            #"(?:window\.)?location(?:\.href)?\s*=\s*(['"])(.*?)\1|(?:window\.)?location\.(?:replace|assign)\s*\(\s*(['"])(.*?)\3\s*\)"#
        if let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        {
            for group in [2, 4] where match.range(at: group).location != NSNotFound {
                let url = (html as NSString).substring(with: match.range(at: group))
                if !rules.social("", destination: url) { return url }
            }
        }
        return nil
    }
    func rejectedFields(_ response: HTTPResponse, form: HTMLForm) -> [HTMLField] {
        var names = Set<String>()
        if let json = object(response.text) {
            if let errors = json["validationFieldErrors"] as? [String: Any] {
                names.formUnion(errors.keys.map(canonical))
            }
            if let errors = json["errors"] as? [String: Any] {
                names.formUnion(errors.keys.map(canonical))
            }
        }
        let page = HTMLPage(response.text)
        for next in page.forms.flatMap(\.fields)
        where next.node.attribute(forName: "aria-invalid")?.stringValue == "true" {
            names.insert(canonical(next.name))
        }
        let errors = page.errors
        let hasFormatError =
            !errors.isEmpty
            && matches("invalid|incorrect|required|not valid|reject|format", errors)
        return form.fields.filter { field in
            let name = field.name
            if names.contains(canonical(name)) { return true }
            guard hasFormatError else { return false }
            let intent = rules.intent(field.descriptor) ?? ""
            guard ["phone", "postcode", "date_of_birth", "email"].contains(intent) else {
                return false
            }
            let pattern =
                NSRegularExpression.escapedPattern(for: name) + "|"
                + (intent == "phone" ? "phone|telephone|mobile" : intent)
            return matches(pattern, errors)
        }
    }
    func explicitCredentials(_ url: URL) -> Bool {
        let candidates = [
            dataDirectory.appendingPathComponent("config/account-credentials.json"),
            dataDirectory.appendingPathComponent("account-credentials.json"),
        ]
        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                let mode = attrs[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0,
                let size = attrs[.size] as? NSNumber, size.intValue <= 65536,
                let data = try? Data(contentsOf: path),
                let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
            else { continue }
            if entries.contains(where: { entry in
                guard let origin = entry["origin"].flatMap(URL.init(string:)),
                    ["existing", "create"].contains(entry["operation"] ?? ""),
                    !(entry["username"] ?? "").isEmpty, !(entry["password"] ?? "").isEmpty
                else { return false }
                return sameOrigin(origin, url)
            }) {
                return true
            }
        }
        return false
    }
    func learnedBrowser(_ url: URL, signature: String) -> Bool {
        let path = dataDirectory.appendingPathComponent("portal_learning.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
            let size = attrs[.size] as? NSNumber, size.intValue <= 262144,
            let data = try? Data(contentsOf: path),
            let db = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = db["strategies"] as? [[String: Any]]
        else { return false }
        let now = Date().timeIntervalSince1970
        return rows.suffix(200).contains { row in
            guard row["host"] as? String == url.host?.lowercased(),
                row["signature"] as? String == signature, row["execution"] as? String == "browser",
                let verified = row["verified_at"] as? Double
            else { return false }
            return now >= verified && now - verified <= 30 * 86400
        }
    }
    func rememberPhone() {
        let key = network.gatewayMAC ?? currentURL.host ?? venue ?? ""
        let path = dataDirectory.appendingPathComponent("phone_policy.json")
        var db =
            (try? Data(contentsOf: path)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: [String]]
            } ?? [:]
        var values = Set(db["phone_validating_venues"] ?? [])
        values.insert(key)
        db["phone_validating_venues"] = values.sorted()
        try? FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: db, options: [.sortedKeys]) {
            try? data.write(to: path, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
    }
}
func encoded(_ fields: [(String, String)]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return fields.map {
        ($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "="
            + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
    }.joined(separator: "&")
}
func object(_ text: String) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
}
func jsonText(_ object: Any) -> String {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap {
        String(data: $0, encoding: .utf8)
    } ?? "{}"
}

func isLocalHost(_ host: String) -> Bool {
    if host == "::" || host.hasPrefix("fc") && host.contains(":")
        || host.hasPrefix("fd") && host.contains(":") || host.hasPrefix("fe80:")
        || host.hasSuffix(".local")
    {
        return true
    }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4 else { return false }
    return octets[0] == 10 || octets[0] == 127 || octets[0] == 0
        || octets[0] == 169 && octets[1] == 254 || octets[0] == 192 && octets[1] == 168
        || octets[0] == 172 && (16...31).contains(octets[1])
}
func jsonRejected(_ text: String) -> Bool {
    guard let json = object(text) else { return false }
    if json["success"] as? Bool == false || json["ok"] as? Bool == false { return true }
    return ["error", "errors", "errorCode", "validationErrors", "validationFieldErrors"].contains {
        key in
        guard let value = json[key], !(value is NSNull) else { return false }
        if let s = value as? String { return !s.isEmpty }
        if let d = value as? [String: Any] { return !d.isEmpty }
        if let a = value as? [Any] { return !a.isEmpty }
        return true
    }
}

func trustedMerakiGrant(landing: URL, target: URL) -> Bool {
    let landingPath = landing.path.hasSuffix("/") ? String(landing.path.dropLast()) : landing.path
    let continuation = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems?.first
    { $0.name == "continue_url" }?.value.flatMap(URL.init(string:))
    return landing.scheme == "https" && target.scheme == "https"
        && hostMatches(landing.host ?? "", "network-auth.com") && target.host == landing.host
        && target.port == landing.port && landingPath.hasPrefix("/splash/")
        && target.path == landingPath + "/grant"
        && ["http", "https"].contains(continuation?.scheme ?? "") && continuation?.host != nil
}

func isBTProviderHost(_ host: String) -> Bool {
    matches(#"(?:^|\.)(?:portal|www|reg)\.btwifi\.com$"#, host)
}

import Foundation

/// Value-only boundary between network I/O, portal policy, and the application.
/// No UI, model, or platform networking API is imported by this module.
public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval
    public var followRedirects: Bool
    public var maximumBodyBytes: Int
    public init(
        url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil,
        timeout: TimeInterval = 10, followRedirects: Bool = true, maximumBodyBytes: Int = 2_097_152
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
        self.followRedirects = followRedirects
        self.maximumBodyBytes = maximumBodyBytes
    }
}

public struct HTTPResponse: Sendable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var truncated: Bool
    public init(
        url: URL, status: Int, headers: [String: String] = [:], body: Data = Data(),
        truncated: Bool = false
    ) {
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
        self.truncated = truncated
    }
    public var text: String { String(decoding: body, as: UTF8.self) }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}

public struct PortalCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var secure: Bool
    public var expires: TimeInterval?
    public init(
        name: String, value: String, domain: String, path: String = "/", secure: Bool = false,
        expires: TimeInterval? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.secure = secure
        self.expires = expires
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
    func cookies() async -> [PortalCookie]
}
extension HTTPClient { public func cookies() async -> [PortalCookie] { [] } }

public struct NetworkSnapshot: Sendable, Equatable {
    public var interface: String?
    public var gatewayIP: String?
    public var gatewayMAC: String?
    public var ssid: String?
    public var dhcpDomain: String?
    public var wifiInterfaces: [String]
    public var captiveHint: Bool
    public var captiveStage: String?
    public var address: String?
    public init(
        interface: String? = nil, gatewayIP: String? = nil, gatewayMAC: String? = nil,
        ssid: String? = nil,
        dhcpDomain: String? = nil, wifiInterfaces: [String] = [], captiveHint: Bool = false,
        captiveStage: String? = nil, address: String? = nil
    ) {
        self.interface = interface
        self.gatewayIP = gatewayIP
        self.gatewayMAC = gatewayMAC
        self.ssid = ssid
        self.dhcpDomain = dhcpDomain
        self.wifiInterfaces = wifiInterfaces
        self.captiveHint = captiveHint
        self.captiveStage = captiveStage
        self.address = address
    }
}

public protocol NetworkInspecting: Sendable { func current() async -> NetworkSnapshot }

/// Saved Persona values, parsed as data (never evaluated as shell text).
public struct PortalIdentity: Sendable {
    public var values: [String: String]
    public init(values: [String: String]) { self.values = values }
    private static let optionalDefaults = [
        "FAKE_TITLE": "Mx", "FAKE_ADDRESS_LINE_1": "1 Example Street",
        "FAKE_CITY": "London", "FAKE_COUNTY": "Greater London",
        "FAKE_COUNTRY": "United Kingdom", "FAKE_GENDER": "Prefer not to say",
        "FAKE_COMPANY": "Independent", "FAKE_OCCUPATION": "Other",
        "FAKE_REASON_FOR_VISIT": "Guest Wi-Fi access",
    ]
    public subscript(_ key: String) -> String { values[key] ?? Self.optionalDefaults[key] ?? "" }
    public var firstName: String { self["FAKE_FIRST_NAME"] }
    public var lastName: String { self["FAKE_LAST_NAME"] }
    public var fullName: String { "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces) }
    public var email: String { self["FAKE_EMAIL"] }
    public var phone: String { self["FAKE_PHONE"] }
    public var postcode: String { self["FAKE_POSTCODE"] }
    public var dateOfBirth: String { self["FAKE_DOB"] }
    public var password: String { self["SIGNUP_PASSWORD"] }
    public var username: String {
        String(email.split(separator: "@", omittingEmptySubsequences: false).first ?? "")
    }
    public var ignoreHotspots: Bool { boolean("IGNORE_HOTSPOTS", default: true) }
    public var enableReassociation: Bool { boolean("ENABLE_REASSOC_FALLBACK", default: false) }
    public func boolean(_ key: String, default fallback: Bool) -> Bool {
        guard let value = values[key], !value.isEmpty else { return fallback }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
    public static func parse(_ text: String) throws -> PortalIdentity {
        var result: [String: String] = [:]
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let equals = line.firstIndex(of: "=") else {
                throw ConfigurationError.invalidLine(index + 1)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
                value.last == first
            {
                value.removeFirst()
                value.removeLast()
            }
            result[key] = value
        }
        return PortalIdentity(values: result)
    }
    public static func load(from url: URL) throws -> PortalIdentity {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConfigurationError.identityNotFound
        }
        let identity = try parse(String(contentsOf: url, encoding: .utf8))
        let required = [
            "FAKE_FIRST_NAME", "FAKE_LAST_NAME", "FAKE_EMAIL", "FAKE_DOB", "FAKE_POSTCODE",
            "FAKE_PHONE", "SIGNUP_PASSWORD",
        ]
        guard required.allSatisfy({ !identity[$0].isEmpty }) else {
            throw ConfigurationError.missingRequiredValues
        }
        return identity
    }
}

public enum ConfigurationError: LocalizedError {
    case invalidLine(Int)
    case missingRequiredValues
    case identityNotFound
    public var errorDescription: String? {
        switch self {
        case .invalidLine(let line): "identity.env line \(line): missing '='."
        case .missingRequiredValues: "identity.env is missing required Persona values."
        case .identityNotFound: "identity.env not found. Save a Persona in Settings."
        }
    }
}

public struct PortalHop: Sendable {
    public var request: HTTPRequest
    public var response: HTTPResponse?
    public init(request: HTTPRequest, response: HTTPResponse?) {
        self.request = request
        self.response = response
    }
}

/// Safe semantic metadata for the activity log. Names are schema hashes;
/// labels/placeholders stay empty and no submitted value is retained.
public struct PortalStepField: Codable, Sendable {
    public var name: String
    public var label: String = ""
    public var placeholder: String = ""
    public var type: String
    public var intent: String
    public var source: String
    public var category: String
    public var maskedValue: String
    public var required: Bool
    public var missing: Bool
    public init(
        name: String, type: String, intent: String, source: String, category: String,
        required: Bool = false, missing: Bool = false
    ) {
        self.name = name
        self.type = type
        self.intent = intent
        self.source = source
        self.category = category
        self.maskedValue = category == "Skipped" ? "" : "[masked]"
        self.required = required
        self.missing = missing
    }
}
public struct PortalStep: Codable, Sendable {
    public var phase: String
    public var title: String
    public var detail: String
    public var status: String
    public var fields: [PortalStepField]
    public init(
        phase: String, title: String, detail: String = "", status: String = "ok",
        fields: [PortalStepField] = []
    ) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.status = status
        self.fields = fields
    }
}

/// A portal submission is only a candidate success. The engine must probe independently.
public struct PortalAttempt: Sendable {
    public enum Outcome: String, Sendable { case submitted, browser, unsupported, failed }
    public var outcome: Outcome
    public var reason: String
    public var portalURL: URL
    public var provider: String
    public var venue: String?
    public var hops: [PortalHop]
    public var actions: Int
    public var pendingSubmission: Bool
    public var corrections: [String: [String]]
    public var signature: String?
    public var steps: [PortalStep]
    public init(
        outcome: Outcome, reason: String = "", portalURL: URL, provider: String = "generic",
        venue: String? = nil,
        hops: [PortalHop] = [], actions: Int = 0, pendingSubmission: Bool = false,
        corrections: [String: [String]] = [:], signature: String? = nil, steps: [PortalStep] = []
    ) {
        self.outcome = outcome
        self.reason = reason
        self.portalURL = portalURL
        self.provider = provider
        self.venue = venue
        self.hops = hops
        self.actions = actions
        self.pendingSubmission = pendingSubmission
        self.corrections = corrections
        self.signature = signature
        self.steps = steps
    }
}

public protocol PortalHandling: Sendable {
    func login(url: URL, identity: PortalIdentity, network: NetworkSnapshot) async -> PortalAttempt
}

import Darwin
import Foundation
import CuppaCore

struct WebViewHandoffRecord: Codable, Equatable {
    let portalURL: String
    let venueFingerprint: String?
    let reason: String
    let capturedHTMLPath: String?
    let writtenAt: TimeInterval
    var deadline: TimeInterval? = nil
    var cookies: [PortalSessionCookie]? = nil
    var signature: String? = nil
    var profileID: String? = nil
    var firstVisit: Bool? = nil
    var venueKey: String? = nil
    var previousActions: Int? = nil
    var pendingSubmission: Bool? = nil
    var corrections: [String: [String]]? = nil
    var manualOnly: Bool? = nil
    var unsupportedReason: String? = nil
    var networkInterface: String? = nil
    var networkGatewayIP: String? = nil

    enum CodingKeys: String, CodingKey {
        case portalURL = "portal_url"
        case venueFingerprint = "venue_fingerprint"
        case reason
        case capturedHTMLPath = "captured_html_path"
        case writtenAt = "written_at"
        case deadline, cookies, signature
        case profileID = "profile_id"
        case firstVisit = "first_visit"
        case venueKey = "venue_key"
        case previousActions = "previous_actions"
        case pendingSubmission = "pending_submission"
        case corrections
        case manualOnly = "manual_only"
        case unsupportedReason = "unsupported_reason"
        case networkInterface = "network_interface"
        case networkGatewayIP = "network_gateway_ip"
    }

    var validatedPortalURL: URL? {
        let reviewedReasons = [
            "no_supported_form_found",
            "meraki_grant_transport_ambiguous",
            "requires_browser",
            "form_hop_limit_reached",
            "submission_accepted_but_portal_remains",
            // Backwards compatibility with handoffs written before the
            // Python reason was stored verbatim.
            "js_render",
        ]
        guard reviewedReasons.contains(reason),
              let url = PortalRequestURL.url(portalURL),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil
        else {
            return nil
        }
        return url
    }

    func isFresh(
        now: Date = Date(),
        maxAge: TimeInterval = 90
    ) -> Bool {
        let age = now.timeIntervalSince1970 - writtenAt
        return age >= 0 && age <= maxAge && (deadline == nil || deadline! > now.timeIntervalSince1970)
    }

    func matches(_ state: AgentState) -> Bool {
        guard let venueFingerprint, !venueFingerprint.isEmpty else {
            return true
        }
        if let domain = state.portalDomain, venueFingerprint == domain {
            return true
        }
        // A shared/virtual gateway MAC (HSRP/GLBP/VRRP) is not a venue
        // identity — never match a handoff to it, or one venue's handoff
        // crosses to an unrelated venue on the same virtual MAC.
        if let mac = state.gatewayMac,
           venueFingerprint == mac,
           !GatewayMAC.isShared(mac) {
            return true
        }
        return false
    }

    static func load(from url: URL) -> WebViewHandoffRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

enum WebViewAutopilotStatus: String, Equatable {
    case submitted
    case unsupported
    case noForm = "no_form"
    case needsMore = "needs_more"
}

struct WebViewAutopilotResult: Equatable {
    let status: WebViewAutopilotStatus
    var detail: String
    let venue: String?
    var fieldsStillFailing: [PortalRejectedField] = []
    var emailIdentityRejected = false
    var provider = "generic"
    var journey = PortalJourney()

    static func decode(_ value: Any?) -> Self? {
        guard let dictionary = value as? [String: Any],
              let rawStatus = dictionary["status"] as? String,
              let status = WebViewAutopilotStatus(rawValue: rawStatus)
        else {
            return nil
        }
        var result = Self(
            status: status,
            detail: dictionary["detail"] as? String ?? "",
            venue: dictionary["venue"] as? String
        )
        if let detail = dictionary["detail"] as? [String: Any] {
            result.fieldsStillFailing = PortalRejectedField.decodeList(detail["fieldsStillFailing"])
            result.emailIdentityRejected = detail["emailIdentityRejected"] as? Bool == true
            result.detail = (detail["reason"] as? String) ?? (result.emailIdentityRejected
                ? "The portal rejected the configured email address"
                : "Please review: " + result.fieldsStillFailing.map { $0.intent }.joined(separator: ", "))
        }
        result.provider = dictionary["provider"] as? String ?? "generic"
        result.journey = PortalJourney.decode(dictionary["journey"]) ?? PortalJourney()
        return result
    }
}

struct PortalSessionCookie: Codable, Equatable {
    let name: String
    let value: String
    let domain: String
    let path: String
    let secure: Bool
    let expires: TimeInterval?
}

struct PortalRejectedField: Codable, Equatable {
    let intent: String
    let name: String?
    let type: String

    static func decodeList(_ value: Any?) -> [Self] {
        (value as? [[String: Any]] ?? []).prefix(100).map {
            let intent = $0["intent"] as? String ?? "unknown"
            let type = $0["type"] as? String ?? "text"
            let valid = PortalStageField(intent: intent, type: type, required: false).isValid
            return Self(intent: valid ? intent : "unknown", name: $0["name"] as? String, type: valid ? type : "text")
        }
    }
}

struct PortalJourney: Codable, Equatable {
    var actions = 0
    var trace: [PortalStageTrace] = []
    var attempts: [String: Bool] = [:]
    var pendingSubmission: Bool? = nil

    static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              var result = try? JSONDecoder().decode(Self.self, from: data),
              (0...32).contains(result.actions), result.attempts.count <= 64,
              result.trace.allSatisfy({ $0.isValid }), result.attempts.keys.allSatisfy({ $0.range(of: "^[a-f0-9]{8}:[a-f0-9]{8}$", options: .regularExpression) != nil }) else { return nil }
        result.trace = Array(result.trace.prefix(64))
        return result
    }

    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }
}

struct PortalStageTrace: Codable, Equatable {
    let signature: String
    let stage: String
    let action: String
    let fields: [PortalStageField]
    var elapsed_ms: Int
    var outcome: String

    var isValid: Bool {
        signature.range(of: "^[a-f0-9]{8}$", options: .regularExpression) != nil
            && action.range(of: "^[a-f0-9]{8}$", options: .regularExpression) != nil
            && ["registration", "activation", "verification", "completion"].contains(stage)
            && ["pending", "next", "submitted", "unchanged", "corrected"].contains(outcome)
            && fields.count <= 100 && fields.allSatisfy { $0.isValid } && elapsed_ms >= 0 && elapsed_ms <= 600_000
    }
}

struct PortalStageField: Codable, Equatable {
    let intent: String
    let type: String
    let required: Bool
    var isValid: Bool {
        let intents = ["unknown", "marketing", "account_password", "verification_code", "email", "phone", "first_name", "last_name", "full_name", "postcode", "address_line_1", "address_line_2", "date_of_birth", "city", "county", "country", "gender", "title", "age", "company", "occupation", "reason_for_visit", "customer_status", "username", "password", "birth_day", "birth_month", "birth_year", "phone_country_code", "firstName", "lastName", "fullName", "address", "addressLine2", "dob", "reasonForVisit", "customerStatus"]
        return (intents + ["issued_identifier", "terms", "marketing_opt_in", "marketing_opt_out"]).contains(intent) && ["text", "email", "tel", "number", "date", "password", "select", "textarea", "radio", "checkbox"].contains(type)
    }
}

final class SharedEngineLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(at url: URL) -> SharedEngineLock? {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return SharedEngineLock(descriptor: descriptor)
    }

    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}

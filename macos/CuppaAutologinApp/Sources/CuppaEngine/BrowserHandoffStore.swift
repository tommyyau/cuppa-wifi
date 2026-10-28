import CoreFoundation
import CuppaCore
import Foundation

/// Durable session bridge across engine invocations and the native WebKit controller.
/// Runtime handoffs remain private because their cookies authorize a portal session.
public struct BrowserHandoffStore: Sendable {
    public let paths: EnginePaths
    public init(paths: EnginePaths) { self.paths = paths }
    public static let browserReasons: Set<String> = [
        "no_supported_form_found", "js_render", "meraki_grant_transport_ambiguous",
        "requires_browser", "form_hop_limit_reached", "submission_accepted_but_portal_remains",
    ]
    private func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }
    public func active(fingerprint: String?, now: TimeInterval) -> Bool {
        guard let value = PrivateFile.object(at: paths.handoff),
            let reason = value["reason"] as? String, Self.browserReasons.contains(reason),
            value["manual_only"] as? Bool != true,
            let written = number(value["written_at"]), now.isFinite, now >= written,
            now - written <= 90,
            value["deadline"] == nil || number(value["deadline"]) != nil,
            (number(value["deadline"]) ?? written + 90) > now,
            let text = value["portal_url"] as? String, let url = PortalRequestURL.url(text),
            ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else { return false }
        if let recorded = value["venue_fingerprint"] as? String, recorded != fingerprint {
            return false
        }
        return true
    }
    public func write(
        attempt: PortalAttempt, network: NetworkSnapshot, fingerprint: String?,
        cookies: [PortalCookie],
        capturedPath: URL?, firstVisit: Bool, now: TimeInterval
    ) throws {
        let cookieData = try JSONEncoder().encode(Array(cookies.prefix(100)))
        var record: [String: Any] = [
            "portal_url": attempt.portalURL.absoluteString,
            "reason": Self.browserReasons.contains(attempt.reason) ? attempt.reason : "js_render",
            "written_at": now, "deadline": now + 90,
            "cookies": try JSONSerialization.jsonObject(with: cookieData),
            "profile_id": attempt.provider, "first_visit": firstVisit,
            "previous_actions": max(0, min(8, attempt.actions)),
            "pending_submission": attempt.pendingSubmission || attempt.actions > 0,
            "corrections": attempt.corrections, "manual_only": attempt.outcome == .unsupported,
            "venue_key": EvidenceStore.hash(fingerprint ?? "unknown"),
        ]
        record["venue_fingerprint"] = fingerprint as Any? ?? NSNull()
        record["network_interface"] = network.interface
        record["network_gateway_ip"] = network.gatewayIP
        record["signature"] = attempt.signature
        record["captured_html_path"] = capturedPath?.path as Any? ?? NSNull()
        if attempt.outcome == .unsupported { record["unsupported_reason"] = attempt.reason }
        try PrivateFile.writeJSON(record, to: paths.handoff)
    }
    public func unsupported(fingerprint: String?, now: TimeInterval) -> String? {
        guard let fingerprint, let value = PrivateFile.object(at: paths.unsupported),
            value["venue_fingerprint"] as? String == fingerprint,
            let written = number(value["written_at"]), now.isFinite, now >= written,
            now - written <= (value["reason"] as? String == "portal_page_unavailable" ? 60 : 86_400)
        else { return nil }
        return value["reason"] as? String
    }
    public func stop(reason: String, fingerprint: String?, now: TimeInterval) throws {
        guard let fingerprint else { return }
        try PrivateFile.writeJSON(
            ["venue_fingerprint": fingerprint, "reason": reason, "written_at": now],
            to: paths.unsupported)
    }
    public func clear() {
        PrivateFile.remove(paths.handoff)
        PrivateFile.remove(paths.unsupported)
    }
}

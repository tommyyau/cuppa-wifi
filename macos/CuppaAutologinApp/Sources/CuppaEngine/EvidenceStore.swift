import CoreFoundation
import CryptoKit
import CuppaCore
import CuppaPortals
import Darwin
import Foundation

/// Private operational evidence and value-free measurements. Failure to write
/// diagnostics must never change the network result or bypass a policy boundary.
public struct EvidenceStore: Sendable {
    public let paths: EnginePaths
    private let resources: URL
    public init(paths: EnginePaths, resources: URL? = nil) {
        self.paths = paths
        self.resources =
            resources ?? Bundle.main.resourceURL
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
    public static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func safeKey(_ value: String) -> String {
        let clean = value.replacingOccurrences(
            of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return clean.isEmpty || clean == "." || clean == ".."
            ? "unknown" : String(clean.prefix(200))
    }
    public static func safeReason(_ value: String?) -> String? {
        guard let value, value.range(of: "^[a-z_]{1,80}$", options: .regularExpression) != nil
        else { return nil }
        return value
    }
    public static func scrub(_ value: String) -> String {
        String(value.prefix(1000)).replacingOccurrences(
            of: "https?://[^\\s]+", with: "[URL omitted]", options: .regularExpression
        )
        .replacingOccurrences(
            of: "[\\w.+-]+@[\\w.-]+", with: "[email masked]", options: .regularExpression
        )
        .replacingOccurrences(of: "\\d{5,}", with: "[number masked]", options: .regularExpression)
    }
    public static func cleanedCaptureURL(_ url: URL) -> String {
        var clean = URLComponents()
        clean.scheme = url.scheme
        clean.host = url.host
        clean.port = url.port
        let vocabulary: Set<String> = [
            "login", "register", "registration", "journey", "auth", "user", "form", "profile",
            "connect", "grant", "splash", "accept", "terms", "check", "process", "redirect",
            "post-auth", "end", "wifi", "guest",
        ]
        clean.path =
            "/"
            + url.path.split(separator: "/").map {
                vocabulary.contains($0.lowercased()) ? String($0) : "redacted"
            }.joined(separator: "/")
        return clean.url?.absoluteString ?? ""
    }
    public func log(
        _ message: String, level: String = "INFO", now: TimeInterval = Date().timeIntervalSince1970
    ) {
        try? PrivateFile.directory(paths.log.deletingLastPathComponent())
        if let size = (try? FileManager.default.attributesOfItem(atPath: paths.log.path)[.size])
            as? NSNumber, size.intValue > 1_000_000
        {
            let backup = URL(fileURLWithPath: paths.log.path + ".1")
            PrivateFile.remove(backup)
            try? FileManager.default.moveItem(at: paths.log, to: backup)
            let backupDescriptor = Darwin.open(backup.path, O_WRONLY | O_NOFOLLOW)
            if backupDescriptor >= 0 {
                _ = fchmod(backupDescriptor, 0o600)
                close(backupDescriptor)
            }
        }
        let descriptor = Darwin.open(
            paths.log.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = fchmod(descriptor, 0o600)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss,SSS"
        let line =
            "\(formatter.string(from: Date(timeIntervalSince1970: now))) \(level) \(message.replacingOccurrences(of: "\n", with: " "))\n"
        _ = line.withCString { Darwin.write(descriptor, $0, strlen($0)) }
    }
    public func trace(
        attempt: String, phase: String, title: String, detail: String = "", status: String = "ok",
        fields: [PortalStepField] = [], now: TimeInterval
    ) {
        guard !attempt.isEmpty else { return }
        let encodedFields =
            (try? JSONEncoder().encode(Array(fields.prefix(100))))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? []
        let event: [String: Any] = [
            "id": UUID().uuidString, "attempt": attempt,
            "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: now)),
            "phase": phase, "title": Self.scrub(title), "detail": Self.scrub(detail),
            "status": status, "fields": encodedFields,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: event),
            let text = String(data: data, encoding: .utf8)
        {
            log("DIAGNOSTIC_STEP " + text, now: now)
        }
    }
    public func progress(
        _ phase: String, title: String, detail: String? = nil, reason: String? = nil,
        actions: Int = 0, newAttempt: Bool = false, now: TimeInterval
    ) {
        let old = newAttempt ? [:] : PrivateFile.object(at: paths.progress) ?? [:]
        var events = old["events"] as? [[String: Any]] ?? []
        events.append(["time": now, "title": title])
        var value: [String: Any] = [
            "format": 1, "started_at": old["started_at"] as? Double ?? now,
            "updated_at": now, "phase": phase, "title": String(title.prefix(160)),
            "actions": max(0, min(8, actions)),
            "navigations": 0, "reasoning_requests": 0,
            "terminal": ["connected", "stopped", "network_unavailable"].contains(phase),
            "events": Array(events.suffix(32)),
        ]
        value["detail"] = detail.map { String($0.prefix(1000)) }
        value["reason"] = Self.safeReason(reason)
        try? PrivateFile.writeJSON(value, to: paths.progress)
        log(
            "portal progress: phase=\(phase) actions=\(actions) reason=\(Self.safeReason(reason) ?? "none")",
            now: now)
    }
    public func confirmAccess(now: TimeInterval) {
        guard let record = PrivateFile.object(at: paths.progress), record["format"] as? Int == 1,
            let phase = record["phase"] as? String,
            ["network_check", "network_unavailable"].contains(phase)
        else { return }
        progress(
            "connected", title: "Internet access confirmed",
            detail: "Internet access verified by the connection check.", now: now)
    }
    public func hasCapture(_ fingerprint: String, successful: Bool = false) -> Bool {
        let directory = paths.captures.appendingPathComponent(Self.safeKey(fingerprint))
        guard successful else { return FileManager.default.fileExists(atPath: directory.path) }
        let children =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
        return children.contains {
            PrivateFile.object(at: $0.appendingPathComponent("diagnostic.json"))?["outcome"]
                as? String == "success"
        }
    }
    @discardableResult public func capture(
        _ attempt: PortalAttempt, fingerprint: String, successful: Bool, now: TimeInterval
    ) -> URL? {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let directory = paths.captures.appendingPathComponent(Self.safeKey(fingerprint))
            .appendingPathComponent(
                formatter.string(from: Date(timeIntervalSince1970: now)) + "-"
                    + UUID().uuidString.prefix(8))
        do {
            try PrivateFile.directory(paths.captures)
            try PrivateFile.directory(directory.deletingLastPathComponent())
            var manifest: [[String: Any]] = []
            var safeHops: [[String: Any]] = []
            for (offset, hop) in attempt.hops.enumerated() {
                let prefix = String(format: "%02d", offset + 1)
                let url = hop.response?.url ?? hop.request.url
                let row: [String: Any] = [
                    "seq": offset + 1, "url": url.absoluteString, "method": hop.request.method,
                    "status": hop.response?.status as Any? ?? NSNull(),
                ]
                var headers = row
                headers["headers"] = hop.response?.headers ?? [:]
                try PrivateFile.writeJSON(
                    headers, to: directory.appendingPathComponent(prefix + "_headers.json"))
                try PrivateFile.write(
                    hop.response?.body ?? Data(),
                    to: directory.appendingPathComponent(prefix + "_body.html"))
                manifest.append(row)
                var safeHop: [String: Any] = [
                    "seq": offset + 1, "method": hop.request.method,
                    "url": Self.cleanedCaptureURL(url),
                    "status": hop.response?.status as Any? ?? NSNull(),
                    "host": url.host ?? "", "body_bytes": hop.response?.body.count ?? 0,
                    "content_type": hop.response?.header("content-type")?.components(
                        separatedBy: ";"
                    ).first ?? "",
                ]
                let structure = PortalStructureReporter.describe(
                    body: hop.response?.text ?? "",
                    contentType: hop.response?.header("content-type") ?? "", resources: resources)
                safeHop.merge(structure, uniquingKeysWith: { _, new in new })
                safeHops.append(safeHop)
            }
            try PrivateFile.writeJSON(
                manifest, to: directory.appendingPathComponent("manifest.json"))
            var diagnostic: [String: Any] = ["outcome": successful ? "success" : "failed"]
            diagnostic["failure_reason"] = Self.safeReason(attempt.reason)
            let rejected = (attempt.steps.last { $0.phase == "validation" }?.fields ?? []).prefix(
                100)
            if !rejected.isEmpty {
                let fields: [[String: Any]] = rejected.map { field in
                    [
                        "name": "field-" + Self.hash(field.name).prefix(12), "label": "",
                        "intent": field.intent, "type": field.type,
                    ]
                }
                diagnostic["failure_detail"] = ["fieldsStillFailing": fields]
            }
            try PrivateFile.writeJSON(
                diagnostic, to: directory.appendingPathComponent("diagnostic.json"))
            // No query strings, tokens, submitted values, arbitrary labels or page bodies.
            var report: [String: Any] = [
                "format": 2, "fingerprint_hash": Self.hash(fingerprint), "hops": safeHops,
                "privacy": [
                    "contains_body": false, "contains_headers": false,
                    "contains_query_strings": false, "contains_field_values": false,
                ],
            ]
            report["failure_reason"] = Self.safeReason(attempt.reason)
            try PrivateFile.writeJSON(
                report, to: directory.appendingPathComponent("safe_report.json"))
            log("portal evidence captured to " + directory.path, now: now)
            return directory
        } catch { return nil }
    }

    /// Accept only bounded structural reports in our own directory, including resolving symlinks.
    public func report(at path: URL?) -> [String: Any]? {
        guard let path else { return nil }
        let resolved = path.resolvingSymlinksInPath()
        guard resolved.deletingLastPathComponent() == paths.journeys.resolvingSymlinksInPath(),
            resolved.pathExtension == "json",
            let raw = PrivateFile.object(at: resolved, maximumBytes: 100_000),
            raw["format"] as? Int == 1,
            let host = raw["host"] as? String,
            host.range(of: "^[a-zA-Z0-9.-]{1,253}$", options: .regularExpression) != nil
        else { return nil }
        let intents: Set<String> = [
            "issued_identifier", "unknown", "marketing", "terms", "marketing_opt_in",
            "marketing_opt_out", "account_password", "verification_code", "email", "phone",
            "first_name", "last_name", "full_name", "postcode", "address_line_1", "address_line_2",
            "date_of_birth", "city", "county", "country", "gender", "title", "age", "company",
            "occupation", "reason_for_visit", "customer_status", "username", "password",
            "birth_day", "birth_month", "birth_year", "phone_country_code", "firstName", "lastName",
            "fullName", "address", "addressLine2", "dob", "reasonForVisit", "customerStatus",
        ]
        let types: Set<String> = [
            "text", "email", "tel", "number", "date", "password", "select", "textarea", "radio",
            "checkbox",
        ]
        func bounded(_ value: Any?, _ max: Int) -> Int {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue
            else { return 0 }
            return Int(min(Double(max), Swift.max(0, number.doubleValue)))
        }
        func fields(_ value: Any?) -> [[String: Any]] {
            ((value as? [[String: Any]]) ?? []).prefix(100).map { field in
                [
                    "intent": intents.contains(field["intent"] as? String ?? "")
                        ? field["intent"] as! String : "unknown",
                    "type": types.contains(field["type"] as? String ?? "")
                        ? field["type"] as! String : "text",
                    "required": field["required"] as? Bool ?? false,
                ]
            }
        }
        func hashed(_ value: Any?, length: Int) -> String? {
            guard let value = value as? String,
                value.range(of: "^[a-f0-9]{\(length)}$", options: .regularExpression) != nil
            else { return nil }
            return value
        }
        let journey = raw["journey"] as? [String: Any] ?? [:]
        let trace: [[String: Any]] = ((journey["trace"] as? [[String: Any]]) ?? []).prefix(64)
            .compactMap { entry in
                guard let signature = hashed(entry["signature"], length: 8) else { return nil }
                return [
                    "signature": signature,
                    "action": hashed(entry["action"], length: 8) ?? "00000000",
                    "elapsed_ms": bounded(entry["elapsed_ms"], 600_000),
                    "outcome": ["pending", "next", "submitted", "unchanged", "corrected"].contains(
                        entry["outcome"] as? String ?? "") ? entry["outcome"]! : "pending",
                    "stage": ["registration", "activation", "verification", "completion"].contains(
                        entry["stage"] as? String ?? "") ? entry["stage"]! : "registration",
                    "fields": fields(entry["fields"]),
                ]
            }
        let provider = raw["provider"] as? String ?? "generic"
        var result: [String: Any] = [
            "format": 1, "host": host.lowercased(),
            "provider": provider.range(of: "^[a-z0-9-]{1,40}$", options: .regularExpression) != nil
                ? provider : "generic",
            "source": raw["source"] as? String == "assisted" ? "assisted" : "automatic",
            "execution": raw["execution"] as? String == "static" ? "static" : "browser",
            "first_visit": raw["first_visit"] as? Bool != false,
            "outcome": [
                "pending_verification", "failed", "unsupported", "verified", "not_verified",
            ].contains(raw["outcome"] as? String ?? "") ? raw["outcome"]! : "failed",
            "journey": ["trace": trace, "actions": bounded(journey["actions"], 32)],
            "fieldsStillFailing": fields(raw["fieldsStillFailing"]).map { field in
                field.filter { $0.key != "required" }
            },
            "emailIdentityRejected": raw["emailIdentityRejected"] as? Bool == true,
            "local_reasoning_available": raw["local_reasoning_available"] as? Bool == true,
            "local_reasoning_requests": bounded(raw["local_reasoning_requests"], 12),
            "local_reasoning_decisions": min(
                bounded(raw["local_reasoning_decisions"], 12),
                bounded(raw["local_reasoning_requests"], 12)),
        ]
        result["signature"] = hashed(raw["signature"], length: 64)
        result["venue_key"] = hashed(raw["venue_key"], length: 64)
        return result
    }
    @discardableResult public func outcome(
        report path: URL?, verified: Bool? = nil, assisted: Bool = false, now: TimeInterval
    ) -> [String: Any]? {
        guard let path, var value = report(at: path) else { return nil }
        if assisted { value["source"] = "assisted" }
        if let verified { value["outcome"] = verified ? "verified" : "not_verified" }
        value["recorded_at"] = now
        try? PrivateFile.writeJSON(value, to: path)
        pruneReports()
        return value
    }
    public func staticOutcome(
        host: String, provider: String, fingerprint: String?, outcome: String, firstVisit: Bool,
        now: TimeInterval
    ) {
        let path = paths.journeys.appendingPathComponent(UUID().uuidString + ".json")
        let value: [String: Any] = [
            "format": 1, "host": host, "provider": provider, "source": "automatic",
            "execution": "static", "first_visit": firstVisit,
            "venue_key": Self.hash(fingerprint ?? "unknown"), "outcome": outcome,
            "journey": ["actions": 0, "trace": []],
        ]
        try? PrivateFile.writeJSON(value, to: path)
        _ = self.outcome(report: path, now: now)
    }
    public func seenVenue(_ fingerprint: String?) -> Bool {
        let key = Self.hash(fingerprint ?? "unknown")
        return reportURLs().contains { url in
            guard let value = report(at: url) else { return false }
            return value["venue_key"] as? String == key && value["outcome"] as? String == "verified"
        }
    }
    public func remember(
        url: URL, signature: String?, execution: String, provider: String, now: TimeInterval
    ) {
        guard let host = url.host, let signature,
            signature.range(of: "^[a-f0-9]{8,64}$", options: .regularExpression) != nil,
            ["static", "browser"].contains(execution)
        else { return }
        var rows = PrivateFile.object(at: paths.learning)?["strategies"] as? [[String: Any]] ?? []
        rows.removeAll { $0["host"] as? String == host && $0["signature"] as? String == signature }
        rows.append([
            "host": host.lowercased(), "signature": signature, "execution": execution,
            "provider": provider, "verified_at": now,
        ])
        try? PrivateFile.writeJSON(
            ["version": 1, "strategies": Array(rows.suffix(200))], to: paths.learning)
    }
    public func summary() -> [String: Int] {
        var counts = Dictionary(
            uniqueKeysWithValues: [
                "automatic_attempts", "automatic_eligible", "automatic_verified",
                "unfamiliar_attempts", "unfamiliar_verified", "assisted_attempts",
                "assisted_verified", "unsupported", "first_visit_eligible", "first_visit_verified",
                "returning_eligible", "returning_verified",
            ].map { ($0, 0) })
        for url in reportURLs() {
            guard let value = report(at: url) else { continue }
            let verified = value["outcome"] as? String == "verified"
            let unsupported = value["outcome"] as? String == "unsupported"
            if value["source"] as? String == "assisted" {
                counts["assisted_attempts", default: 0] += 1
                if verified { counts["assisted_verified", default: 0] += 1 }
                continue
            }
            counts["automatic_attempts", default: 0] += 1
            if unsupported {
                counts["unsupported", default: 0] += 1
            } else {
                counts["automatic_eligible", default: 0] += 1
            }
            if verified { counts["automatic_verified", default: 0] += 1 }
            let cohort = value["first_visit"] as? Bool == false ? "returning" : "first_visit"
            if !unsupported { counts[cohort + "_eligible", default: 0] += 1 }
            if verified { counts[cohort + "_verified", default: 0] += 1 }
            if value["provider"] as? String == "generic" {
                if !unsupported { counts["unfamiliar_attempts", default: 0] += 1 }
                if verified { counts["unfamiliar_verified", default: 0] += 1 }
            }
        }
        return counts
    }
    private func reportURLs() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: paths.journeys, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
    }
    private func pruneReports() {
        let sorted = reportURLs().sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast)
                < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast)
        }
        for url in sorted.prefix(max(0, sorted.count - 200)) { PrivateFile.remove(url) }
    }
}

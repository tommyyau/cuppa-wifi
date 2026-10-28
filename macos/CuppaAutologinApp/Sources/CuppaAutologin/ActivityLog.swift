import Foundation
import Darwin

struct ActivityEvent: Identifiable, Equatable {
    let id: String
    let timestamp: String
    let occurredAt: Date?
    let title: String
    let detail: String
    let kind: Kind
    let category: Category
    let gatewayMac: String?

    enum Kind: Equatable {
        case success
        case attention
        case information
    }

    enum Category: Equatable {
        case automaticSignIn
        case connection
        case portal
        case attention
        case recovery
        case configuration
        case quality
    }
}

enum ActivityLog {
    static func parse(_ text: String) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        for (index, rawLine) in text.split(separator: "\n").enumerated() {
            let line = String(rawLine)
            if let range = line.range(of: "DIAGNOSTIC_STEP ") {
                // Keep useful speed outcomes in the ordinary history; full traces
                // and intermediate measurement steps belong in Troubleshooting.
                if let data = String(line[range.upperBound...]).data(using: .utf8),
                   let raw = try? JSONDecoder().decode(DiagnosticStep.self, from: data),
                   raw.phase == "quality", raw.status != "running", raw.title != "What this means" {
                    let step = DiagnosticTrace.sanitized(raw)
                    events.append(ActivityEvent(id: step.id, timestamp: step.timestamp,
                        occurredAt: step.occurredAt, title: step.title, detail: step.detail,
                        kind: step.status == "ok" ? .success : .attention,
                        category: .quality, gatewayMac: nil))
                }
                continue
            }
            guard line.count >= 24 else { continue }
            let timestamp = String(line.prefix(19))
            let messageStart = line.index(line.startIndex, offsetBy: 24)
            let message = String(line[messageStart...])

            let summary: (
                String,
                String,
                ActivityEvent.Kind,
                ActivityEvent.Category
            )?
            if message.contains("captive portal detected") {
                summary = (
                    "Portal detected",
                    venue(from: message).map { "Signing in at \($0)" }
                        ?? "Starting automatic sign-in",
                    .information,
                    .portal
                )
            } else if message.contains("auto-login succeeded")
                        || message.contains("webview auto-login succeeded")
            {
                summary = (
                    "Connected automatically",
                    venue(from: message).map {
                        "Internet access was restored at \($0)"
                    } ?? "Internet access was restored",
                    .success,
                    .automaticSignIn
                )
            } else if message.contains("connection established") {
                summary = (
                    "Connected successfully",
                    venue(from: message).map { "Internet is available on \($0)" }
                        ?? "Internet access is available",
                    .success,
                    .connection
                )
            } else if message.contains(
                "webview detected unsupported portal:"
            ) {
                summary = (
                    "Sign-in needs verification",
                    attentionDetail(
                        for: failureReason(from: message)
                    ),
                    .attention,
                    .attention
                )
            } else if message.contains("can't auto-login")
                        || message.contains("auto-login failed")
                        || message.contains("login failed")
            {
                summary = (
                    "Sign-in needs attention",
                    attentionDetail(
                        for: failureReason(from: message)
                    ),
                    .attention,
                    .attention
                )
            } else if message.contains("network unavailable:") {
                summary = (
                    "Wi-Fi access unavailable",
                    "Network checks could not find a usable connection or portal. Try another network or ask the venue to check its Wi-Fi.",
                    .attention, .attention
                )
            } else if message.contains("portal discovered without DNS:") {
                summary = ("Portal recovered", "Found a sign-in redirect using a direct network check.",
                           .information, .recovery)
            } else if message.contains("reassociat") {
                summary = (
                    "Wi-Fi refreshed",
                    "A guarded network re-association was used",
                    .information,
                    .recovery
                )
            } else if message.contains("ERROR") || line.contains(" ERROR ") {
                summary = (
                    "Configuration needs attention",
                    "Open Troubleshooting and copy a support summary when asking for help",
                    .attention,
                    .configuration
                )
            } else {
                summary = nil
            }

            guard let summary else { continue }
            events.append(
                ActivityEvent(
                    id: "\(timestamp)-\(index)",
                    timestamp: timestamp,
                    occurredAt: parseTimestamp(timestamp),
                    title: summary.0,
                    detail: summary.1,
                    kind: summary.2,
                    category: summary.3,
                    gatewayMac: value(
                        named: "gateway_mac",
                        from: message
                    )
                )
            )
        }
        return events
    }

    private static func parseTimestamp(_ timestamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: timestamp)
    }

    private static func venue(from message: String) -> String? {
        value(named: "venue", from: message)
    }

    private static func failureReason(from message: String) -> String? {
        guard let range = message.range(of: "reason=") else {
            return nil
        }
        let tail = message[range.upperBound...]
        let value = tail.prefix {
            !$0.isWhitespace && $0 != "," && $0 != ")"
        }
        return value.isEmpty ? nil : String(value.prefix(160))
    }

    static func attentionDetail(for reason: String?) -> String {
        if reason == "privacy_email_required" {
            return "This portal needs a deliverable privacy relay email"
        }
        if reason?.hasPrefix(
            "wireless_social_required_field_unsupported"
        ) == true {
            return "This portal requested a field the app will not guess"
        }
        if reason?.hasPrefix("required_field_unmapped") == true {
            return "An unfamiliar required field was saved for support"
        }
        switch reason {
        case "portal_page_unavailable": return "The Wi-Fi sign-in page returned an error or website search. Ask the venue to check its portal, or use another network."
        case "connectivity_unverified": return "Sign-in was submitted, but internet access could not be verified"
        case "sms_verification": return "Enter the code sent to your phone"
        case "two_factor": return "Enter your authenticator or two-factor code"
        case "email_verification": return "Open the verification link sent to your email"
        case "payment_required": return "This portal requires payment"
        case "validation_exhausted": return "The portal rejected the available formats; review the form"
        case "account_credentials_required": return "This portal needs your account username and password"
        case "unknown_required_field": return "This portal needs a detail the app cannot supply"
        case "verification_code_required":
            return "This portal needs a real SMS or email verification code"
        case "captcha_required":
            return "This portal requires a CAPTCHA"
        case "voucher_or_venue_credential_required":
            return "This portal needs a voucher, booking, or paid credential"
        case "sponsor_approval_required":
            return "This network requires approval from a real sponsor"
        case "government_identity_required":
            return "This network requires genuine identity details"
        case "marketing_consent_required":
            return "The app will not accept mandatory marketing"
        case "social_login_required":
            return "This portal requires a real social account"
        default:
            return "The portal could not be completed safely"
        }
    }

    private static func value(
        named name: String,
        from message: String
    ) -> String? {
        guard let range = message.range(of: "\(name)=") else {
            return nil
        }
        let tail = message[range.upperBound...]
        let terminators = [
            " portal_domain=",
            " ssid=",
            " source=",
            " gateway_mac=",
            " reason=",
            ", captured",
        ]
        let end = terminators.compactMap {
            tail.range(of: $0)?.lowerBound
        }.min() ?? tail.endIndex
        let value = tail[..<end].trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else { return nil }
        return String(value.prefix(80))
    }
}

/// Stable DIAGNOSTIC_STEP format shared by the native engine and browser.
struct DiagnosticField: Codable, Equatable {
    var name: String
    var label: String
    var placeholder: String
    var type: String
    var intent: String
    var source: String
    var category: String
    var maskedValue: String
    var confidence: Double? = nil
}

struct DiagnosticStep: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var attempt: String
    var timestamp: String = ISO8601DateFormatter().string(from: Date())
    var phase: String
    var title: String
    var detail: String
    var status: String
    var fields: [DiagnosticField] = []

    var occurredAt: Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: timestamp)
        formatter.formatOptions = [.withInternetDateTime]
        return fractional ?? formatter.date(from: timestamp)
    }

    var displayTime: String {
        occurredAt?.formatted(date: .omitted, time: .standard)
            ?? String(timestamp.dropFirst(11).prefix(8))
    }
}

struct DiagnosticAttempt: Identifiable, Equatable {
    var id: String
    var steps: [DiagnosticStep]
}

enum DiagnosticTrace {
    static func clean(_ text: String) -> String {
        var result = String(text.prefix(400))
        for (pattern, replacement) in [
            (#"https?://[^\s]+"#, "[URL omitted]"),
            (#"[\w.+-]+@[\w.-]+"#, "[email masked]"),
            (#"\d{5,}"#, "[number masked]")
        ] {
            result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return result
    }

    static func sanitized(_ step: DiagnosticStep) -> DiagnosticStep {
        var step = step
        step.title = clean(step.title)
        step.detail = clean(step.detail)
        step.fields = step.fields.map { field in
            var field = field
            field.name = clean(field.name)
            field.label = clean(field.label)
            field.placeholder = clean(field.placeholder)
            field.type = clean(field.type)
            field.intent = clean(field.intent)
            field.source = clean(field.source)
            field.category = clean(field.category)
            // Do not trust bridge/log values to already be redacted.
            field.maskedValue = field.maskedValue.isEmpty ? "" : "[masked]"
            return field
        }
        return step
    }

    static func parse(_ text: String) -> [DiagnosticAttempt] {
        var attempts: [DiagnosticAttempt] = []
        var seen: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let range = line.range(of: "DIAGNOSTIC_STEP "),
                  let data = String(line[range.upperBound...]).data(using: .utf8),
                  let raw = try? JSONDecoder().decode(DiagnosticStep.self, from: data),
                  seen.insert(raw.id).inserted else { continue }
            let step = sanitized(raw)
            if let index = attempts.firstIndex(where: { $0.id == step.attempt }) {
                attempts[index].steps.append(step)
            } else {
                attempts.append(DiagnosticAttempt(id: step.attempt, steps: [step]))
            }
        }
        return Array(attempts.suffix(20).reversed())
    }

    static func append(_ step: DiagnosticStep, to url: URL) {
        guard let data = try? JSONEncoder().encode(sanitized(step)),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = Data(("DIAGNOSTIC_STEP " + json + "\n").utf8)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        line.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { _ = write(fd, base, bytes.count) }
        }
    }
}

import CryptoKit
import CuppaCore
import Foundation

extension PortalSession {
    func schemaField(
        _ name: String, intent: String? = nil, type: String = "text", category: String? = nil,
        required: Bool = false, missing: Bool = false
    ) -> PortalStepField {
        let schemaID =
            "field-"
            + SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined().prefix(
                12)
        let knownTypes: Set<String> = [
            "text", "email", "tel", "password", "hidden", "number", "date", "select", "textarea",
            "checkbox", "radio", "submit", "range",
        ]
        let resolved = intent ?? rules.intent(["name": name, "type": type]) ?? "unknown"
        return PortalStepField(
            name: schemaID, type: knownTypes.contains(type) ? type : "unknown", intent: resolved,
            source: provider == "generic" ? "Native semantics" : "Provider rule",
            category: category ?? (resolved == "unknown" ? "Skipped" : "Persona " + resolved),
            required: required, missing: missing)
    }
    func recordForm(_ form: HTMLForm) {
        let fields = form.fields.prefix(100).map { field -> PortalStepField in
            let intent = rules.intent(field.descriptor) ?? "unknown"
            let consent = rules.consent(field.wording)
            let category: String
            if field.disabled {
                category = "Skipped"
            } else if field.type == "hidden" || field.node.attribute(forName: "readonly") != nil {
                category = "Server-provided"
            } else if ["checkbox", "radio", "select"].contains(field.type)
                && consent.hasPrefix("marketing")
            {
                category = "Marketing declined"
            } else if field.type == "checkbox" && consent == "terms" {
                category = "Terms consent"
            } else if field.type == "submit" {
                category = "Portal action"
            } else if ["verification_code", "account_password", "issued_identifier"].contains(
                intent)
            {
                category = "Manual input required"
            } else {
                category = intent == "unknown" ? "Skipped" : "Persona " + intent
            }
            return schemaField(
                field.name.isEmpty ? field.descriptor["id"] ?? "" : field.name, intent: intent,
                type: field.type,
                category: category, required: field.required,
                missing: field.required && intent == "unknown" && field.value.isEmpty
                    && !field.disabled
                    && !["hidden", "submit", "checkbox", "radio"].contains(field.type))
        }
        record(
            PortalStep(
                phase: "form", title: "Inspected portal form",
                detail: "Field meanings and consent controls evaluated", fields: fields))
        let consentFields = fields.filter {
            ["Terms consent", "Marketing declined"].contains($0.category)
        }
        if !consentFields.isEmpty {
            record(
                PortalStep(
                    phase: "consent", title: "Evaluated portal consent",
                    detail: "Terms evaluated; optional marketing defaults to decline",
                    fields: consentFields))
        }
    }
    func recordAction(method: String, fields: [(String, String)] = []) {
        let metadata = fields.prefix(100).map { pair -> PortalStepField in
            let intent = rules.intent(["name": pair.0])
            let category: String
            if ["password", "username", "account_password"].contains(intent ?? "") {
                category = "Server-provided"
            } else if let intent, persona(intent, identity) != nil {
                category = "Persona " + intent
            } else if rules.consent(pair.0) == "terms" {
                category = "Terms consent"
            } else if rules.consent(pair.0).hasPrefix("marketing") {
                category = "Marketing declined"
            } else {
                category = "Portal request"
            }
            return schemaField(pair.0, intent: intent, category: category)
        }
        record(
            PortalStep(
                phase: "action", title: "Sent portal action",
                detail: method == "POST"
                    ? "Submitted form through scoped HTTP"
                    : "Followed an explicit portal continuation", fields: metadata))
    }
    func recordCorrection(_ fields: [HTMLField]) {
        record(
            PortalStep(
                phase: "validation", title: "Portal rejected field format",
                detail: "Only alternate encodings of the same Persona are considered",
                status: "rejected",
                fields: fields.prefix(100).map {
                    schemaField(
                        $0.name, intent: rules.intent($0.descriptor), type: $0.type,
                        category: "Format correction", required: $0.required)
                }))
    }
    func record(_ step: PortalStep) {
        steps.append(step)
        steps = Array(steps.suffix(32))
    }
}

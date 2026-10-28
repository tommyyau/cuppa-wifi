import Foundation
import Darwin

struct FakeIdentity: Equatable {
    var firstName: String
    var lastName: String
    var email: String
    var dateOfBirth: String
    var postcode: String
    var phone: String
    var password: String
    var title: String
    var addressLine1: String
    var addressLine2: String
    var city: String
    var county: String
    var country: String
    var gender: String
    var company: String
    var occupation: String
    var reasonForVisit: String
    var reassociationEnabled: Bool
    var ignoreHotspots: Bool

    static let sarahChen = FakeIdentity(
        firstName: "Sarah",
        lastName: "Chen",
        email: "sarah.chen.wifi@gmail.com",
        dateOfBirth: "1988-03-14",
        postcode: "SW1A 1AA",
        phone: "07700900123",
        password: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        title: "Mx",
        addressLine1: "1 Example Street",
        addressLine2: "",
        city: "London",
        county: "Greater London",
        country: "United Kingdom",
        gender: "Prefer not to say",
        company: "Independent",
        occupation: "Other",
        reasonForVisit: "Guest Wi-Fi access",
        reassociationEnabled: false,
        ignoreHotspots: true
    )

    static func generated() -> FakeIdentity {
        let firstNames = [
            "Sarah", "Alex", "Morgan", "Jamie", "Robin", "Casey", "Avery",
        ]
        let lastNames = [
            "Chen", "Morgan", "Taylor", "Patel", "Rivera", "Kim", "Bell",
        ]
        let first = firstNames.randomElement() ?? "Sarah"
        let last = lastNames.randomElement() ?? "Chen"
        let nonce = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(10)
            .lowercased()
        let phoneSuffix = String(format: "%03d", Int.random(in: 0 ... 999))
        return FakeIdentity(
            firstName: first,
            lastName: last,
            email: "\(first.lowercased()).\(last.lowercased()).\(nonce)@gmail.com",
            dateOfBirth: "1988-03-14",
            postcode: "SW1A 1AA",
            phone: "07700900\(phoneSuffix)",
            password: UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            title: "Mx",
            addressLine1: "1 Example Street",
            addressLine2: "",
            city: "London",
            county: "Greater London",
            country: "United Kingdom",
            gender: "Prefer not to say",
            company: "Independent",
            occupation: "Other",
            reasonForVisit: "Guest Wi-Fi access",
            reassociationEnabled: false,
            ignoreHotspots: true
        )
    }
}

enum IdentityStore {
    /// Shared with the native engine, including its isolated test data override.
    static var file: URL {
        SystemPaths.sharedIdentityFile()
    }

    /// Preserve a Persona from an older install until shared config is saved.
    private static var legacyFile: URL {
        SystemPaths.legacyEngine.appendingPathComponent(
            "config/identity.env"
        )
    }

    static func load() -> FakeIdentity {
        let text = (try? String(contentsOf: file, encoding: .utf8))
            ?? (try? String(contentsOf: legacyFile, encoding: .utf8))
        guard let text else {
            return .sarahChen
        }
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let equals = line.firstIndex(of: "=")
            else { continue }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\""))
                || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        let fallback = FakeIdentity.sarahChen
        return FakeIdentity(
            firstName: values["FAKE_FIRST_NAME"] ?? fallback.firstName,
            lastName: values["FAKE_LAST_NAME"] ?? fallback.lastName,
            email: values["FAKE_EMAIL"] ?? fallback.email,
            dateOfBirth: values["FAKE_DOB"] ?? fallback.dateOfBirth,
            postcode: values["FAKE_POSTCODE"] ?? fallback.postcode,
            phone: values["FAKE_PHONE"] ?? fallback.phone,
            password: values["SIGNUP_PASSWORD"] ?? fallback.password,
            title: values["FAKE_TITLE"] ?? fallback.title,
            addressLine1: values["FAKE_ADDRESS_LINE_1"]
                ?? fallback.addressLine1,
            addressLine2: values["FAKE_ADDRESS_LINE_2"]
                ?? fallback.addressLine2,
            city: values["FAKE_CITY"] ?? fallback.city,
            county: values["FAKE_COUNTY"] ?? fallback.county,
            country: values["FAKE_COUNTRY"] ?? fallback.country,
            gender: values["FAKE_GENDER"] ?? fallback.gender,
            company: values["FAKE_COMPANY"] ?? fallback.company,
            occupation: values["FAKE_OCCUPATION"] ?? fallback.occupation,
            reasonForVisit: values["FAKE_REASON_FOR_VISIT"]
                ?? fallback.reasonForVisit,
            reassociationEnabled: bool(
                values["ENABLE_REASSOC_FALLBACK"],
                default: false
            ),
            ignoreHotspots: bool(
                values["IGNORE_HOTSPOTS"],
                default: true
            )
        )
    }

    static func save(_ identity: FakeIdentity, to file: URL = IdentityStore.file) throws {
        for (label, value) in [("First name", identity.firstName), ("Last name", identity.lastName),
                               ("Email", identity.email), ("Date of birth", identity.dateOfBirth),
                               ("Postcode", identity.postcode), ("Phone", identity.phone),
                               ("Password", identity.password)] {
            if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw SaveError.requiredField(label)
            }
        }
        let values = [
            ("FAKE_FIRST_NAME", identity.firstName),
            ("FAKE_LAST_NAME", identity.lastName),
            ("FAKE_EMAIL", identity.email),
            ("FAKE_DOB", identity.dateOfBirth),
            ("FAKE_POSTCODE", identity.postcode),
            ("FAKE_PHONE", identity.phone),
            ("FAKE_TITLE", identity.title),
            ("FAKE_ADDRESS_LINE_1", identity.addressLine1),
            ("FAKE_ADDRESS_LINE_2", identity.addressLine2),
            ("FAKE_CITY", identity.city),
            ("FAKE_COUNTY", identity.county),
            ("FAKE_COUNTRY", identity.country),
            ("FAKE_GENDER", identity.gender),
            ("FAKE_COMPANY", identity.company),
            ("FAKE_OCCUPATION", identity.occupation),
            ("FAKE_REASON_FOR_VISIT", identity.reasonForVisit),
            ("SIGNUP_PASSWORD", identity.password),
            ("MARKETING_OPT_IN", "false"),
            ("IGNORE_HOTSPOTS", String(identity.ignoreHotspots)),
            ("ENABLE_REASSOC_FALLBACK", String(identity.reassociationEnabled)),
        ]
        // Both readers parse one KEY=VALUE per line. Validate before touching
        // disk so pasted line breaks cannot introduce another setting.
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        guard values.allSatisfy({ $0.1.rangeOfCharacter(from: forbidden) == nil }) else {
            throw SaveError.controlCharacter
        }
        // Readers remove exactly one outer quote pair without shell expansion
        // or unescaping; this preserves literal quotes, equals and whitespace.
        let text = "# Fictional portal identity managed by Cuppa Wi-Fi.\n"
            + values.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: "\n") + "\n"
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path
        )
        let temporary = directory.appendingPathComponent(".identity-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    enum SaveError: LocalizedError {
        case controlCharacter
        case requiredField(String)

        var errorDescription: String? {
            switch self {
            case .controlCharacter:
                "Persona fields must stay on one line and cannot contain control characters."
            case .requiredField(let label):
                "\(label) is required. Enter a fictional value before saving."
            }
        }
    }

    private static func bool(_ value: String?, default defaultValue: Bool) -> Bool {
        guard let value else { return defaultValue }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}

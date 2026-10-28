import Foundation
import Darwin

/// Explicit account authorization, scoped to one browser origin. Separate
/// from the fictional signup persona; never included in model observations.
struct PortalCredentials: Codable, Equatable {
    enum Operation: String, Codable { case existing, create }
    let origin: String
    let operation: Operation
    let username: String
    let password: String

    func authorizes(_ url: URL) -> Bool {
        guard let expected = URL(string: origin), !username.isEmpty, !password.isEmpty,
              ["http", "https"].contains(expected.scheme ?? "") else { return false }
        return expected.scheme == url.scheme && expected.host?.lowercased() == url.host?.lowercased()
            && (expected.port ?? (expected.scheme == "https" ? 443 : 80)) == (url.port ?? (url.scheme == "https" ? 443 : 80))
    }

    var javascriptDictionary: [String: Any] {
        ["operation": operation.rawValue, "username": username, "password": password]
    }

    static func load(for url: URL) -> Self? {
        let file = SystemPaths.sharedIdentityFile().deletingLastPathComponent().appendingPathComponent("account-credentials.json")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: file), data.count < 65536,
              let entries = try? JSONDecoder().decode([Self].self, from: data) else { return nil }
        return entries.first { $0.authorizes(url) }
    }
}

/// Accounts observed in a successful browser journey. A shared provider host
/// alone is not a venue: callers must supply a non-shared gateway scope too.
struct PortalAccountStore {
    struct Entry: Codable {
        let scope: String
        let credentials: PortalCredentials
    }

    let file: URL
    static var shared: Self {
        Self(file: SystemPaths.sharedIdentityFile().deletingLastPathComponent()
            .appendingPathComponent("verified-portal-accounts.json"))
    }

    private func entries() -> [Entry] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o077 == 0,
              let data = try? Data(contentsOf: file), data.count <= 1_048_576,
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries
    }

    func load(for url: URL, scope: String?) -> PortalCredentials? {
        guard let scope, !scope.isEmpty else { return nil }
        return entries().first { $0.scope == scope && $0.credentials.operation == .existing
            && $0.credentials.authorizes(url) }?.credentials
    }

    func remember(_ account: PortalCredentials, scope: String) throws {
        guard !scope.isEmpty, let url = URL(string: account.origin), account.authorizes(url) else { return }
        var saved = entries().filter { !($0.scope == scope && $0.credentials.authorizes(url)) }
        saved.append(Entry(scope: scope, credentials: PortalCredentials(origin: account.origin,
            operation: .existing, username: account.username, password: account.password)))
        let data = try JSONEncoder().encode(Array(saved.suffix(200)))
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, file.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct PortalAutofillPayload {
    static func make(identity: FakeIdentity, credentials: [String: Any], isSubframe: Bool,
                     frameOrigin: String? = nil, mainOrigin: String? = nil,
                     signupOrigin: String? = nil) -> [String: Any] {
        var persona = identity.javascriptDictionary
        let trustedFrame = frameOrigin.map { $0 == mainOrigin || $0 == signupOrigin } ?? false
        if isSubframe && !trustedFrame { persona.removeValue(forKey: "password") }
        return ["identity": persona, "credentials": credentials]
    }
}

extension FakeIdentity {
    var javascriptDictionary: [String: Any] {
        [
            "firstName": firstName,
            "lastName": lastName,
            "email": email,
            "phone": phone,
            "postcode": postcode,
            "address": addressLine1,
            "addressLine1": addressLine1,
            "addressLine2": addressLine2,
            "city": city,
            "county": county,
            "country": country,
            "gender": gender,
            "title": title,
            "company": company,
            "occupation": occupation,
            "reasonForVisit": reasonForVisit,
            "dob": dateOfBirth,
            "password": password,
        ]
    }
}

/// WebKit's security origin authorizes the frame; document paths only classify
/// signup versus sign-in. Inherited documents use their embedding page's path.
struct PortalFrameURL {
    static func make(scheme: String, host: String, port: Int, requestURL: URL?, mainURL: URL?) -> URL? {
        guard ["http", "https"].contains(scheme), !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        components.port = port == 0 ? (scheme == "https" ? 443 : 80) : port
        if let requestURL, let originURL = components.url,
           requestURL.scheme == originURL.scheme,
           requestURL.host?.lowercased() == originURL.host?.lowercased(),
           (requestURL.port ?? (scheme == "https" ? 443 : 80)) == components.port {
            return requestURL
        }
        let document = requestURL.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil } ?? mainURL
        components.percentEncodedPath = document.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
        return components.url
    }

    static func isSignup(_ url: URL) -> Bool {
        url.path.range(of: "signup|register", options: [.regularExpression, .caseInsensitive]) != nil
    }
}

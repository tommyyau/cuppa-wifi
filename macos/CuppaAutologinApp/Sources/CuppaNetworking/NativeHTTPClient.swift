import CuppaCore
import Foundation

public struct HTTPTransportError: Error, Sendable, Equatable {
    public let category: String
    public let connected: Bool
    public init(category: String, connected: Bool) {
        self.category = category
        self.connected = connected
    }
}

public actor NativeHTTPClient: HTTPClient {
    private let network: NetworkSnapshot
    private let resolver: ScopedDNSResolver
    private let trustAnchors: [Data]
    private struct CookieEntry {
        let cookie: HTTPCookie
        let hostOnly: Bool
        let origin: String
    }
    private var jar: [CookieEntry] = []
    public init(network: NetworkSnapshot) {
        trustAnchors = []
        self.network = network
        resolver = ScopedDNSResolver(network: network)
    }
    // Internal isolated-fixture trust roots. Production clients always use
    // system roots; the original hostname policy remains mandatory in both.
    init(network: NetworkSnapshot, trustAnchors: [Data]) {
        self.network = network
        self.trustAnchors = trustAnchors
        resolver = ScopedDNSResolver(network: network)
    }
    public func cookies() async -> [PortalCookie] {
        pruneCookies()
        return jar.map {
            PortalCookie(
                name: $0.cookie.name, value: $0.cookie.value, domain: $0.cookie.domain,
                path: $0.cookie.path, secure: $0.cookie.isSecure,
                expires: $0.cookie.expiresDate?.timeIntervalSince1970)
        }
    }
    private func pruneCookies() {
        jar.removeAll { $0.cookie.expiresDate.map { $0 <= Date() } ?? false }
    }
    private func cookieHeader(_ url: URL) -> String {
        pruneCookies()
        let host = url.host?.lowercased() ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        return jar.filter { entry in
            let domain = entry.cookie.domain.lowercased().trimmingCharacters(
                in: CharacterSet(charactersIn: "."))
            let matches =
                entry.hostOnly
                ? host == entry.origin : host == domain || host.hasSuffix("." + domain)
            let cp = entry.cookie.path
            let pathMatches =
                path == cp
                || (path.hasPrefix(cp)
                    && (cp.hasSuffix("/") || path.dropFirst(cp.count).hasPrefix("/")))
            return matches && pathMatches && (!entry.cookie.isSecure || url.scheme == "https")
        }.sorted { $0.cookie.path.count > $1.cookie.path.count }.map {
            "\($0.cookie.name)=\($0.cookie.value)"
        }.joined(separator: "; ")
    }
    private func ingest(_ fields: [(String, String)], url: URL) {
        guard let host = url.host?.lowercased() else { return }
        for (key, value) in fields where key.lowercased() == "set-cookie" {
            for cookie in HTTPCookie.cookies(
                withResponseHeaderFields: ["Set-Cookie": value], for: url)
            {
                let domain = cookie.domain.lowercased().trimmingCharacters(
                    in: CharacterSet(charactersIn: "."))
                guard host == domain || host.hasSuffix("." + domain) else { continue }
                // Never let a single-label domain cookie escape its origin.
                let hostOnly = !value.lowercased().split(separator: ";").dropFirst().contains {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("domain=")
                }
                guard hostOnly || domain.contains(".") else { continue }
                jar.removeAll {
                    $0.cookie.name == cookie.name && $0.cookie.domain == cookie.domain
                        && $0.cookie.path == cookie.path
                }
                jar.append(CookieEntry(cookie: cookie, hostOnly: hostOnly, origin: host))
            }
        }
        pruneCookies()
    }
    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard request.timeout.isFinite, request.timeout > 0, request.maximumBodyBytes >= 0 else {
            throw NativeNetworkError.invalidRequest
        }
        let deadline = Date().addingTimeInterval(min(request.timeout, 120))
        var current = request
        for hop in 0...10 {
            let (response, fields) = try await single(current, deadline: deadline)
            ingest(fields, url: current.url)
            guard request.followRedirects, [301, 302, 303, 307, 308].contains(response.status),
                let location = response.header("location"),
                let next = PortalRequestURL.url(location, relativeTo: current.url)?.absoluteURL
            else { return response }
            guard hop < 10 else { throw NativeNetworkError.redirectLimit }
            if origin(current.url) != origin(next) {
                current.headers = current.headers.filter {
                    !["authorization", "cookie", "proxy-authorization"].contains(
                        $0.key.lowercased())
                }
            }
            if (response.status == 303 && current.method.uppercased() != "HEAD")
                || ([301, 302].contains(response.status) && current.method.uppercased() == "POST")
            {
                current.method = "GET"
                current.body = nil
                current.headers = current.headers.filter {
                    !["content-type", "content-length", "transfer-encoding"].contains(
                        $0.key.lowercased())
                }
            }
            current.url = next
        }
        throw NativeNetworkError.redirectLimit
    }
    private func origin(_ url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
    private func single(_ request: HTTPRequest, deadline: Date) async throws -> (
        HTTPResponse, [(String, String)]
    ) {
        guard let scheme = request.url.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let urlHost = request.url.host, request.url.user == nil, request.url.password == nil,
            let port = UInt16(exactly: request.url.port ?? (scheme == "https" ? 443 : 80)), port > 0
        else { throw NativeNetworkError.invalidURL }
        let host = urlHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let tlsName = scheme == "https" ? host : nil
        var connection: ScopedConnection
        do {
            connection = try ScopedConnection(
                host: host, port: port, interface: network.interface, tlsName: tlsName,
                deadline: min(
                    deadline, Date().addingTimeInterval(min(3, max(0.1, request.timeout * 0.4)))),
                trustAnchors: trustAnchors)
            try await connection.open()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if case .invalidInterface = error as? NativeNetworkError { throw error }
            // DNS fallback cannot make a proxy-selected path direct. Preserve the diagnosis.
            if case .proxyDetected = error as? NativeNetworkError { throw error }
            if ScopedDNSResolver.isIPAddress(host) || network.interface == nil { throw error }
            let addresses = try await resolver.fallback(host, deadline: deadline)
            var last: Error = error
            var connected: ScopedConnection?
            for address in addresses {
                do {
                    let candidate = try ScopedConnection(
                        host: address, port: port, interface: network.interface, tlsName: tlsName,
                        deadline: deadline, trustAnchors: trustAnchors)
                    try await candidate.open()
                    connected = candidate
                    break
                } catch { last = error }
            }
            guard let connected else { throw last }
            connection = connected
        }
        // The connection deadline must cover all I/O, not only the connect budget.
        connection.deadlineForIO = deadline
        defer { connection.close() }
        do {
            let method = request.method.uppercased()
            guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) || $0 == 45 })
            else { throw NativeNetworkError.invalidRequest }
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
            components.fragment = nil
            let path =
                (components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath)
                + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
            var headers = request.headers.filter {
                ![
                    "host", "connection", "content-length", "transfer-encoding",
                    "proxy-authorization", "accept-encoding",
                ].contains($0.key.lowercased())
            }
            headers["Host"] =
                host.contains(":")
                ? "[\(host)]:\(port)" : (request.url.port == nil ? host : "\(host):\(port)")
            headers["Connection"] = "close"
            headers["Accept-Encoding"] = "identity"
            if !headers.keys.contains(where: { $0.lowercased() == "cookie" }) {
                let cookie = cookieHeader(request.url)
                if !cookie.isEmpty { headers["Cookie"] = cookie }
            }
            if let body = request.body { headers["Content-Length"] = String(body.count) }
            guard
                headers.allSatisfy({ key, value in
                    !key.isEmpty && key.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 58 })
                        && !value.contains("\r") && !value.contains("\n")
                })
            else { throw NativeNetworkError.invalidRequest }
            var wire = Data("\(method) \(path) HTTP/1.1\r\n".utf8)
            for (key, value) in headers { wire.append(Data("\(key): \(value)\r\n".utf8)) }
            wire.append(Data("\r\n".utf8))
            if let body = request.body { wire.append(body) }
            try await connection.send(wire)
            let reader = HTTPStreamReader(connection: connection)
            var fields: [(String, String)] = []
            var status = 0
            for _ in 0..<8 {
                let header = try await reader.until(Data("\r\n\r\n".utf8), limit: 16_384)
                let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                guard first.count >= 2, first[0].hasPrefix("HTTP/1."), let code = Int(first[1]),
                    (100...599).contains(code)
                else { throw NativeNetworkError.invalidResponse }
                status = code
                fields = try lines.dropFirst().filter { !$0.isEmpty }.map { line in
                    guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "),
                        !line.hasPrefix("\t")
                    else { throw NativeNetworkError.invalidResponse }
                    return (
                        String(line[..<colon]),
                        line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    )
                }
                if status >= 200 { break }
            }
            guard status >= 200 else { throw NativeNetworkError.invalidResponse }
            var responseHeaders: [String: String] = [:]
            for (key, value) in fields {
                let existing = responseHeaders.keys.first { $0.lowercased() == key.lowercased() }
                if let existing {
                    responseHeaders[existing]! += ", " + value
                } else {
                    responseHeaders[key] = value
                }
            }
            let lowerHeaders = Dictionary(
                fields.map { ($0.0.lowercased(), $0.1) }, uniquingKeysWith: { first, _ in first })
            var body = Data()
            var truncated = false
            let limit = min(request.maximumBodyBytes, 8_388_608)
            if limit == 0 {
                truncated =
                    method != "HEAD" && ![204, 304].contains(status)
                    && lowerHeaders["content-length"] != "0"
            } else if method != "HEAD" && ![204, 304].contains(status) {
                if let transfer = lowerHeaders["transfer-encoding"] {
                    guard transfer.lowercased() == "chunked" else {
                        throw NativeNetworkError.invalidResponse
                    }
                    while true {
                        let line = try await reader.until(Data("\r\n".utf8), limit: 1024)
                        let raw =
                            String(decoding: line, as: UTF8.self).split(
                                separator: ";", maxSplits: 1
                            ).first ?? ""
                        guard let count = Int(raw.trimmingCharacters(in: .whitespaces), radix: 16),
                            count >= 0
                        else { throw NativeNetworkError.invalidResponse }
                        if count == 0 { break }
                        let allowed = min(count, max(0, limit - body.count) + 1)
                        body.append(try await reader.exactly(allowed))
                        if body.count > limit {
                            body = body.prefix(limit)
                            truncated = true
                            break
                        }
                        guard try await reader.exactly(2) == Data("\r\n".utf8) else {
                            throw NativeNetworkError.invalidResponse
                        }
                    }
                } else if let raw = lowerHeaders["content-length"] {
                    let lengths = fields.filter { $0.0.lowercased() == "content-length" }.map {
                        $0.1
                    }
                    guard Set(lengths).count == 1, let count = Int(raw), count >= 0 else {
                        throw NativeNetworkError.invalidResponse
                    }
                    body = try await reader.exactly(min(count, limit + 1))
                    truncated = count > limit
                    if truncated { body = body.prefix(limit) }
                } else {
                    while body.count <= limit {
                        let data = try await reader.next(
                            maximum: max(1, min(65_536, limit - body.count + 1)))
                        if data.isEmpty { break }
                        body.append(data)
                    }
                    truncated = body.count > limit
                    if truncated { body = body.prefix(limit) }
                }
            }
            return (
                HTTPResponse(
                    url: request.url, status: status, headers: responseHeaders, body: body,
                    truncated: truncated), fields
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw HTTPTransportError(
                category: ConnectivityProbe.errorCategory(error), connected: true)
        }
    }
}
private final class HTTPStreamReader {
    var buffer = Data()
    let connection: ScopedConnection
    init(connection: ScopedConnection) { self.connection = connection }
    func until(_ delimiter: Data, limit: Int) async throws -> Data {
        while true {
            if let range = buffer.range(of: delimiter) {
                // Data can retain a nonzero startIndex after body bytes are
                // consumed. Bound the current line, not its storage index.
                guard buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= limit
                else { throw NativeNetworkError.oversizedHeader }
                let value = Data(buffer[..<range.lowerBound])
                buffer.removeSubrange(..<range.upperBound)
                return value
            }
            guard buffer.count <= limit else { throw NativeNetworkError.oversizedHeader }
            let more = try await connection.receive(
                maximum: min(16_384, limit + delimiter.count - buffer.count))
            guard !more.isEmpty else { throw NativeNetworkError.invalidResponse }
            buffer.append(more)
        }
    }
    func exactly(_ count: Int) async throws -> Data {
        var data = Data()
        while data.count < count {
            let next = try await next(maximum: min(65_536, count - data.count))
            guard !next.isEmpty else { throw NativeNetworkError.invalidResponse }
            data.append(next)
        }
        return data
    }
    func next(maximum: Int) async throws -> Data {
        if !buffer.isEmpty {
            let data = Data(buffer.prefix(maximum))
            buffer.removeFirst(data.count)
            return data
        }
        return try await connection.receive(maximum: maximum)
    }
}

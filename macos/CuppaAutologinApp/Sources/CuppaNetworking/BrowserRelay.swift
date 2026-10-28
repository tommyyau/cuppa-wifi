import CuppaCore
import Darwin
@preconcurrency import Dispatch
import Foundation
import Network
import Security

public struct BrowserRelayConfiguration: Sendable {
    public let port: UInt16
    public let username: String
    public let password: String
    public var credential: String { username + ":" + password }
}
public actor BrowserRelay {
    private let network: NetworkSnapshot
    private let portalHost: String
    private let portalPort: UInt16
    private let configCredential: String
    private let resolveHost: (@Sendable (String, Date) async throws -> [String])?
    private let resolver: ScopedDNSResolver
    private var listener: NWListener?
    private var sessions: [UUID: (ScopedConnection, ScopedConnection?)] = [:]
    private let connectionTelemetry = RelayConnectionTelemetry()
    public private(set) var port: UInt16 = 0
    public nonisolated var connections: Int { connectionTelemetry.value }
    public init(
        network: NetworkSnapshot, portalURL: URL, credential: String? = nil,
        resolveHost: (@Sendable (String, Date) async throws -> [String])? = nil
    ) throws {
        guard let host = portalURL.host, ["http", "https"].contains(portalURL.scheme),
            let port = UInt16(exactly: portalURL.port ?? (portalURL.scheme == "https" ? 443 : 80)),
            port > 0
        else { throw NativeNetworkError.invalidURL }
        if let gateway = network.gatewayIP,
            !ScopedDNSResolver.isIPAddress(gateway) || Self.isForbiddenGateway(gateway)
        {
            throw NativeNetworkError.forbiddenDestination
        }
        self.resolveHost = resolveHost
        self.network = network
        portalHost = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        portalPort = port
        resolver = ScopedDNSResolver(network: network)
        if let credential {
            guard (32...200).contains(credential.utf8.count), credential.contains(":"),
                !credential.contains("\r"), !credential.contains("\n")
            else { throw NativeNetworkError.invalidRequest }
            configCredential = credential
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw NativeNetworkError.invalidRequest
            }
            configCredential = "cuppa:" + bytes.map { String(format: "%02x", $0) }.joined()
        }
    }
    public func start() async throws -> BrowserRelayConfiguration {
        if listener != nil {
            guard port > 0 else { throw NativeNetworkError.stopped }
            return configuration()
        }
        connectionTelemetry.reset()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let box = Completion(continuation)
                let timeout = DispatchWorkItem {
                    box.finish(.failure(NativeNetworkError.timeout))
                    listener.cancel()
                }
                ScopedConnection.queue.asyncAfter(deadline: .now() + 5, execute: timeout)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        timeout.cancel()
                        box.finish(.success(()))
                    case .failed(let error):
                        timeout.cancel()
                        box.finish(.failure(error))
                    case .cancelled:
                        timeout.cancel()
                        box.finish(.failure(NativeNetworkError.stopped))
                    default: break
                    }
                }
                listener.start(queue: ScopedConnection.queue)
            }
            guard self.listener === listener, let assigned = listener.port?.rawValue else {
                throw NativeNetworkError.stopped
            }
            port = assigned
            return configuration()
        } catch {
            self.listener = nil
            throw error
        }
    }
    private func configuration() -> BrowserRelayConfiguration {
        let parts = configCredential.split(
            separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return BrowserRelayConfiguration(
            port: port, username: String(parts[0]), password: String(parts[1]))
    }
    public func stop() {
        listener?.cancel()
        listener = nil
        port = 0
        for (_, pair) in sessions {
            pair.0.close()
            pair.1?.close()
        }
        sessions.removeAll()
    }
    public func permitted(host: String, port: UInt16) -> Bool {
        let host = host.lowercased()
        if host == portalHost && port == portalPort { return true }
        if host == network.gatewayIP && [80, 443, 1000].contains(port) { return true }
        guard [80, 443].contains(port), !["localhost", "localhost.localdomain"].contains(host),
            !host.hasSuffix(".local"), !host.hasSuffix(".localhost")
        else { return false }
        if ScopedDNSResolver.isIPAddress(host) { return Self.isGlobalAddress(host) }
        return host.utf8.count <= 253 && host.contains(".")
            && host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
                !label.isEmpty && label.utf8.count <= 63
                    && label.utf8.allSatisfy {
                        (48...57).contains($0) || (97...122).contains($0) || $0 == 45
                    }
            }
    }
    public static func isGlobalAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let x = UInt32(bigEndian: v4.s_addr)
            let a = x >> 24
            let b = x >> 16 & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254)
                || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b)) || (a == 198 && [18, 19].contains(b))
            {
                return false
            }
            if (x & 0xffff_ff00) == 0xc000_0000 || (x & 0xffff_ff00) == 0xc000_0200
                || (x & 0xffff_ff00) == 0xc633_6400 || (x & 0xffff_ff00) == 0xcb00_7100
            {
                return false
            }
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, host, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes.prefix(12) == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255] {
            return isGlobalAddress(bytes.suffix(4).map(String.init).joined(separator: "."))
        }
        // Restrict to ordinary global unicast; exclude documentation and transition/local ranges.
        return bytes[0] & 0xe0 == 0x20
            && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
    }
    private static func isForbiddenGateway(_ host: String) -> Bool {
        host == "0.0.0.0" || host == "::" || host == "::1" || host.hasPrefix("127.")
            || host.lowercased().hasPrefix("ff")
            || (host.split(separator: ".").first.flatMap { Int($0) }.map { $0 >= 224 } ?? false)
    }
    private func accept(_ incoming: NWConnection) async {
        guard listener != nil, sessions.count < 32 else {
            incoming.cancel()
            return
        }
        let id = UUID()
        let local = ScopedConnection(connection: incoming, deadline: Date().addingTimeInterval(5))
        sessions[id] = (local, nil)
        defer {
            sessions[id]?.0.close()
            sessions[id]?.1?.close()
            sessions.removeValue(forKey: id)
        }
        do {
            try await local.open()
            var header = Data()
            // Read one byte until the header ends so no tunnel bytes can be swallowed.
            while !header.suffix(4).elementsEqual([13, 10, 13, 10]) && header.count <= 16_384 {
                let data = try await local.receive(maximum: 1)
                if data.isEmpty { return }
                header.append(data)
            }
            guard header.count <= 16_384, let text = String(data: header, encoding: .ascii) else {
                throw NativeNetworkError.invalidRequest
            }
            let lines = text.components(separatedBy: "\r\n")
            let parts = lines[0].split(separator: " ")
            let fields = lines.dropFirst().compactMap { line -> (String, String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                return (
                    line[..<colon].lowercased(),
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                )
            }
            let auths = fields.filter { $0.0 == "proxy-authorization" }
            let expected = "Basic " + Data(configCredential.utf8).base64EncodedString()
            guard auths.count == 1, Self.constantTimeEqual(auths[0].1, expected) else {
                try await local.send(
                    Data(
                        "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Cuppa Wi-Fi\"\r\nContent-Length: 0\r\n\r\n"
                            .utf8))
                return
            }
            guard parts.count == 3, parts[0] == "CONNECT", parts[2] == "HTTP/1.1",
                let colon = parts[1].lastIndex(of: ":"),
                let destinationPort = UInt16(parts[1][parts[1].index(after: colon)...])
            else { throw NativeNetworkError.invalidRequest }
            let host = parts[1][..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                .lowercased()
            guard permitted(host: host, port: destinationPort) else {
                try await local.send(
                    Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n".utf8))
                return
            }
            let deadline = Date().addingTimeInterval(8)
            let addresses: [String]
            if let resolveHost {
                addresses = try await resolveHost(host, deadline)
            } else {
                addresses = try await resolver.resolve(host, deadline: deadline)
            }
            guard
                host == portalHost || host == network.gatewayIP
                    || addresses.allSatisfy(Self.isGlobalAddress)
            else { throw NativeNetworkError.forbiddenDestination }
            var remote: ScopedConnection?
            for address in addresses {
                do {
                    let candidate = try ScopedConnection(
                        host: address, port: destinationPort, interface: network.interface,
                        deadline: deadline)
                    try await candidate.open()
                    remote = candidate
                    break
                } catch { continue }
            }
            guard let remote, sessions[id] != nil else { throw NativeNetworkError.stopped }
            sessions[id] = (local, remote)
            connectionTelemetry.increment()
            local.deadlineForIO = Date().addingTimeInterval(8)
            try await local.send(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            let end = Date().addingTimeInterval(600)
            await withTaskGroup(of: Void.self) { group in
                for (source, destination) in [(local, remote), (remote, local)] {
                    group.addTask {
                        defer {
                            source.close()
                            destination.close()
                        }
                        do {
                            while Date() < end {
                                source.deadlineForIO = min(end, Date().addingTimeInterval(8))
                                let data = try await source.receive()
                                if data.isEmpty { return }
                                destination.deadlineForIO = min(end, Date().addingTimeInterval(8))
                                try await destination.send(data)
                            }
                        } catch {}
                    }
                }
                await group.waitForAll()
            }
        } catch {
            if sessions[id]?.1 == nil {
                local.deadlineForIO = Date().addingTimeInterval(1)
                try? await local.send(
                    Data("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n".utf8))
            }
        }
    }
    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let left = [UInt8](a.utf8)
        let right = [UInt8](b.utf8)
        var mismatch = left.count ^ right.count
        for i in 0..<max(left.count, right.count) {
            mismatch |= Int((i < left.count ? left[i] : 0) ^ (i < right.count ? right[i] : 0))
        }
        return mismatch == 0
    }
}

private final class RelayConnectionTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    func reset() {
        lock.lock()
        count = 0
        lock.unlock()
    }
}

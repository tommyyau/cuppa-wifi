import CuppaCore
import Darwin
@preconcurrency import Dispatch
import Foundation
import Network
import Security

public enum NativeNetworkError: Error, Sendable, Equatable {
    case invalidURL
    case invalidInterface(String)
    case timeout, invalidResponse, oversizedHeader, redirectLimit, dnsFailure, forbiddenDestination,
        invalidRequest, stopped, proxyDetected
}
final class Completion<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var continuation: CheckedContinuation<T, Error>?
    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let current = continuation
        continuation = nil
        lock.unlock()
        current?.resume(with: result)
    }
}
final class ScopedConnection: @unchecked Sendable {
    let connection: NWConnection
    private let deadlineLock = NSLock()
    private var storedDeadline: Date
    var deadline: Date {
        get {
            deadlineLock.lock()
            defer { deadlineLock.unlock() }
            return storedDeadline
        }
        set {
            deadlineLock.lock()
            storedDeadline = newValue
            deadlineLock.unlock()
        }
    }
    var deadlineForIO: Date {
        get { deadline }
        set { deadline = newValue }
    }
    static let queue = DispatchQueue(label: "CuppaNetworking.io", attributes: .concurrent)
    init(
        host: String, port: UInt16, interface: String?, tlsName: String? = nil, udp: Bool = false,
        deadline: Date, trustAnchors: [Data] = []
    ) throws {
        let parameters: NWParameters
        if udp {
            parameters = .udp
        } else if let tlsName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsName)
            // Bind certificate verification to the original host even for DNS-fallback IP endpoints.
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { _, protocolTrust, complete in
                    let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                    SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, tlsName as CFString))
                    SecTrustSetNetworkFetchAllowed(trust, false)
                    if !trustAnchors.isEmpty {
                        let certificates = trustAnchors.compactMap {
                            SecCertificateCreateWithData(nil, $0 as CFData)
                        }
                        SecTrustSetAnchorCertificates(trust, certificates as CFArray)
                        SecTrustSetAnchorCertificatesOnly(trust, true)
                    }
                    complete(SecTrustEvaluateWithError(trust, nil))
                }, Self.queue)
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        parameters.preferNoProxies = true
        if let interface {
            guard let found = Self.interface(named: interface, deadline: deadline) else {
                throw NativeNetworkError.invalidInterface(interface)
            }
            parameters.requiredInterface = found
        }
        self.storedDeadline = deadline
        self.connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }
    init(connection: NWConnection, deadline: Date) {
        self.connection = connection
        self.storedDeadline = deadline
    }
    private static func interface(named name: String, deadline: Date) -> NWInterface? {
        guard if_nametoindex(name) != 0 else { return nil }
        // A captive Wi-Fi route may be absent from the default path. Query each
        // interface type independently so it remains bindable before promotion.
        let monitors = [
            NWPathMonitor(), NWPathMonitor(requiredInterfaceType: .wifi),
            NWPathMonitor(requiredInterfaceType: .wiredEthernet),
            NWPathMonitor(requiredInterfaceType: .loopback),
            NWPathMonitor(requiredInterfaceType: .other),
        ]
        let semaphore = DispatchSemaphore(value: 0)
        let box = InterfaceBox()
        for monitor in monitors {
            monitor.pathUpdateHandler = { path in
                if let found = path.availableInterfaces.first(where: { $0.name == name }) {
                    box.value = found
                    semaphore.signal()
                }
            }
            monitor.start(queue: queue)
        }
        _ = semaphore.wait(timeout: .now() + min(1, max(0, deadline.timeIntervalSinceNow)))
        monitors.forEach { $0.cancel() }
        return box.value
    }
    func open() async throws {
        try await operation { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.connection.requestEstablishmentReport(queue: Self.queue) { report in
                        if report?.usedProxy == true {
                            completion(.failure(NativeNetworkError.proxyDetected))
                            self.connection.cancel()
                        } else {
                            completion(.success(()))
                        }
                    }
                case .waiting(let error): if case .tls = error { completion(.failure(error)) }
                case .failed(let error): completion(.failure(error))
                case .cancelled: completion(.failure(NativeNetworkError.stopped))
                default: break
                }
            }
            self.connection.start(queue: Self.queue)
        }
    }
    func send(_ data: Data) async throws {
        try await operation { (completion: @escaping @Sendable (Result<Void, Error>) -> Void) in
            self.connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { completion(.failure(error)) } else { completion(.success(())) }
                })
        }
    }
    func receive(maximum: Int = 65_536) async throws -> Data {
        try await operation { completion in
            self.connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) {
                data, _, _, error in
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(data ?? Data()))
                }
            }
        }
    }
    private func operation<T: Sendable>(
        _ body: @escaping @Sendable (@escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let seconds = deadline.timeIntervalSinceNow
        guard seconds > 0 else {
            connection.cancel()
            throw NativeNetworkError.timeout
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let box = Completion(continuation)
                let timer = DispatchWorkItem {
                    box.finish(.failure(NativeNetworkError.timeout))
                    self.connection.cancel()
                }
                Self.queue.asyncAfter(deadline: .now() + seconds, execute: timer)
                body { result in
                    timer.cancel()
                    box.finish(result)
                }
                if Task.isCancelled {
                    timer.cancel()
                    box.finish(.failure(CancellationError()))
                    self.connection.cancel()
                }
            }
        } onCancel: {
            self.connection.cancel()
        }
    }
    func close() { connection.cancel() }
    deinit { connection.cancel() }
}
private final class InterfaceBox: @unchecked Sendable {
    let lock = NSLock()
    private var stored: NWInterface?
    var value: NWInterface? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

public enum DNSPacket {
    public static func query(host: String, id: UInt16, type: UInt16) throws -> Data {
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard let ascii = URL(string: "http://\(normalized)/")?.host, ascii.utf8.count <= 253 else {
            throw NativeNetworkError.dnsFailure
        }
        let labels = ascii.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty && labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else {
            throw NativeNetworkError.dnsFailure
        }
        var result = Data()
        for value: UInt16 in [id, 0x0100, 1, 0, 0, 0] {
            result.append(contentsOf: [UInt8(value >> 8), UInt8(value & 255)])
        }
        for label in labels {
            result.append(UInt8(label.utf8.count))
            result.append(contentsOf: label.utf8)
        }
        result.append(0)
        result.append(contentsOf: [UInt8(type >> 8), UInt8(type & 255), 0, 1])
        return result
    }
    public static func addresses(_ data: Data, id: UInt16) throws -> [String] {
        let bytes = [UInt8](data)
        func u16(_ at: Int) throws -> Int {
            guard at + 1 < bytes.count else { throw NativeNetworkError.dnsFailure }
            return Int(bytes[at]) << 8 | Int(bytes[at + 1])
        }
        guard bytes.count >= 12, try u16(0) == Int(id), try u16(2) & 0x8000 != 0,
            try u16(2) & 0x0200 == 0
        else { throw NativeNetworkError.dnsFailure }
        if try u16(2) & 15 != 0 { return [] }
        func skip(_ original: Int) throws -> Int {
            var offset = original
            var count = 0
            while offset < bytes.count && count < 128 {
                count += 1
                let length = Int(bytes[offset])
                offset += 1
                if length & 0xc0 == 0xc0 {
                    guard offset < bytes.count else { throw NativeNetworkError.dnsFailure }
                    return offset + 1
                }
                guard length <= 63, offset + length <= bytes.count else {
                    throw NativeNetworkError.dnsFailure
                }
                if length == 0 { return offset }
                offset += length
            }
            throw NativeNetworkError.dnsFailure
        }
        var offset = 12
        for _ in 0..<(try u16(4)) {
            offset = try skip(offset)
            offset += 4
            guard offset <= bytes.count else { throw NativeNetworkError.dnsFailure }
        }
        var addresses: [String] = []
        // Accept answers only. Unrelated additional records must not become the target host.
        for _ in 0..<(try u16(6)) {
            offset = try skip(offset)
            let type = try u16(offset)
            let klass = try u16(offset + 2)
            let length = try u16(offset + 8)
            offset += 10
            guard offset + length <= bytes.count else { throw NativeNetworkError.dnsFailure }
            if klass == 1 && ((type == 1 && length == 4) || (type == 28 && length == 16)) {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let record = Array(bytes[offset..<(offset + length)])
                _ = record.withUnsafeBytes {
                    inet_ntop(
                        type == 1 ? AF_INET : AF_INET6, $0.baseAddress, &buffer,
                        socklen_t(buffer.count))
                }
                let address = String(
                    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self
                )
                if !addresses.contains(address) { addresses.append(address) }
            }
            offset += length
        }
        return addresses
    }
}
public typealias DNSQueryFunction =
    @Sendable (
        _ interface: String, _ server: String, _ hostname: String, _ type: UInt16, _ deadline: Date
    ) async throws -> [String]
public struct DNSDiagnosticQuery: Sendable {
    public let hostname: String
    public let server: String
    public let addresses: [String]?
    public let error: String?
    public let elapsedMilliseconds: Int
    public init(
        hostname: String, server: String, addresses: [String]? = nil, error: String? = nil,
        elapsedMilliseconds: Int = 0
    ) {
        self.hostname = hostname
        self.server = server
        self.addresses = addresses
        self.error = error
        self.elapsedMilliseconds = elapsedMilliseconds
    }
    public var json: [String: Any] {
        var fields: [String: Any] = [
            "hostname": hostname, "server": server, "elapsed_ms": elapsedMilliseconds,
        ]
        if let addresses { fields["addresses"] = addresses }
        if let error { fields["error"] = error }
        return fields
    }
}
public struct DNSDiagnosticMatrix: Sendable {
    public let serversTried: [String]
    public let serversResponding: [String]
    public let queries: [DNSDiagnosticQuery]
    public let deadlineReached: Bool
    public init(
        serversTried: [String], serversResponding: [String], queries: [DNSDiagnosticQuery],
        deadlineReached: Bool = false
    ) {
        self.serversTried = serversTried
        self.serversResponding = serversResponding
        self.queries = queries
        self.deadlineReached = deadlineReached
    }
    public var json: [String: Any] {
        [
            "servers_tried": serversTried, "servers_responding": serversResponding,
            "queries": queries.map(\.json), "deadline_reached": deadlineReached,
        ]
    }
}

public actor ScopedDNSResolver {
    private let systemResolve: (@Sendable (String, Date) async throws -> [String])?
    private let injectedQuery: DNSQueryFunction?
    private let injectedServers: [String]?
    private let dnsPort: UInt16
    private let interface: String?
    private let gateway: String?
    private let commands: any SystemCommandRunning
    private var cache: [String: [String]] = [:]
    public init(
        network: NetworkSnapshot, commands: any SystemCommandRunning = NativeSystemCommands(),
        servers: [String]? = nil, dnsPort: UInt16 = 53, queryServer: DNSQueryFunction? = nil,
        systemResolve: (@Sendable (String, Date) async throws -> [String])? = nil
    ) {
        self.systemResolve = systemResolve
        self.injectedQuery = queryServer
        self.injectedServers = servers
        self.dnsPort = dnsPort
        interface = network.interface
        gateway = network.gatewayIP
        self.commands = commands
    }
    public static func servers(
        dns: String, packet: String, interface: String, gateway: String? = nil
    ) -> [String] {
        var servers: [String] = []
        func append(_ value: String) {
            if isIPAddress(value), !servers.contains(value) { servers.append(value) }
        }
        for block in dns.components(separatedBy: "resolver #").dropFirst()
        where block.contains("(\(interface))") || block.contains("interface : \(interface)\n") {
            for line in block.components(separatedBy: .newlines) where line.contains("nameserver[")
            {
                if let colon = line.firstIndex(of: ":") {
                    append(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
            }
        }
        func packetValues(_ marker: String) -> [String] {
            packet.components(separatedBy: .newlines).filter { $0.contains(marker) }.flatMap {
                $0.components(separatedBy: marker).last!.trimmingCharacters(
                    in: CharacterSet(charactersIn: " {}")
                ).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        if servers.isEmpty { packetValues("domain_name_server (ip_mult):").forEach(append) }
        packetValues("router (ip_mult):").forEach(append)
        if let gateway { append(gateway) }
        return servers
    }
    public func resolve(_ host: String, deadline: Date) async throws -> [String] {
        if Self.isIPAddress(host) { return [host] }
        if let cached = cache[host] { return cached }
        if let systemResolve {
            if let addresses = try? await systemResolve(host, deadline), !addresses.isEmpty {
                cache[host] = addresses
                return addresses
            }
            return try await fallback(host, deadline: deadline)
        }
        let addresses: [String] =
            (try? await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[String], Error>) in
                let box = Completion(continuation)
                ScopedConnection.queue.asyncAfter(
                    deadline: .now() + min(2, max(0.01, deadline.timeIntervalSinceNow))
                ) { box.finish(.failure(NativeNetworkError.timeout)) }
                DispatchQueue.global(qos: .utility).async {
                    var hints = addrinfo()
                    hints.ai_socktype = SOCK_STREAM
                    hints.ai_family = AF_UNSPEC
                    var first: UnsafeMutablePointer<addrinfo>?
                    guard getaddrinfo(host, nil, &hints, &first) == 0 else {
                        box.finish(.failure(NativeNetworkError.dnsFailure))
                        return
                    }
                    defer { if let first { freeaddrinfo(first) } }
                    var addresses: [String] = []
                    var current = first
                    while let entry = current {
                        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        if getnameinfo(
                            entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer,
                            socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0
                        {
                            let value = String(
                                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                as: UTF8.self)
                            if !addresses.contains(value) { addresses.append(value) }
                        }
                        current = entry.pointee.ai_next
                    }
                    box.finish(.success(addresses))
                }
            }) ?? []
        if !addresses.isEmpty {
            cache[host] = addresses
            return addresses
        }
        return try await fallback(host, deadline: deadline)
    }
    /// Only used after Network.framework's scoped hostname resolution fails.
    public func fallback(_ host: String, deadline: Date) async throws -> [String] {
        if Self.isIPAddress(host) { return [host] }
        if let cached = cache[host] { return cached }
        guard let interface else { throw NativeNetworkError.dnsFailure }
        let servers = await configuredServers(deadline: deadline)
        for type: UInt16 in [1, 28] {
            for server in servers {
                guard deadline > Date() else { throw NativeNetworkError.timeout }
                do {
                    let addresses = try await query(
                        interface: interface, server: server, host: host, type: type,
                        deadline: min(deadline, Date().addingTimeInterval(2)))
                    if !addresses.isEmpty {
                        cache[host] = addresses
                        return addresses
                    }
                } catch { if Task.isCancelled { throw CancellationError() } }
            }
        }
        throw NativeNetworkError.dnsFailure
    }
    private func configuredServers(deadline: Date) async -> [String] {
        if let injectedServers { return injectedServers }
        guard let interface else { return [] }
        async let dns = commands.run(
            "/usr/sbin/scutil", arguments: ["--dns"],
            timeout: min(5, max(0.01, deadline.timeIntervalSinceNow)))
        async let packet = commands.run(
            "/usr/sbin/ipconfig", arguments: ["getpacket", interface],
            timeout: min(5, max(0.01, deadline.timeIntervalSinceNow)))
        return Self.servers(
            dns: await dns.text, packet: await packet.text, interface: interface, gateway: gateway)
    }
    private func query(
        interface: String, server: String, host: String, type: UInt16, deadline: Date
    ) async throws -> [String] {
        if let injectedQuery {
            return try await injectedQuery(interface, server, host, type, deadline)
        }
        let id = UInt16.random(in: .min ... .max)
        let connection = try ScopedConnection(
            host: server, port: dnsPort, interface: interface, udp: true, deadline: deadline)
        defer { connection.close() }
        try await connection.open()
        try await connection.send(DNSPacket.query(host: host, id: id, type: type))
        return try DNSPacket.addresses(await connection.receive(maximum: 4096), id: id)
    }
    public func diagnosticMatrix(hosts extraHosts: [String], deadline requestedDeadline: Date) async
        -> DNSDiagnosticMatrix
    {
        let deadline = min(requestedDeadline, Date().addingTimeInterval(30))
        var servers = await configuredServers(deadline: deadline)
        for server in [gateway, "1.1.1.1"].compactMap({ $0 }) where !servers.contains(server) {
            servers.append(server)
        }
        servers = Array(servers.prefix(16))
        var hosts = ["captive.apple.com", "connectivitycheck.gstatic.com", "purpleportal.net"]
        for host in extraHosts where !host.isEmpty && !hosts.contains(host) { hosts.append(host) }
        hosts = Array(hosts.prefix(12))
        var results: [DNSDiagnosticQuery] = []
        var timeouts: [String: Int] = [:]
        outer: for host in hosts {
            for server in servers {
                if Date() >= deadline || Task.isCancelled { break outer }
                if timeouts[server, default: 0] >= 2 { continue }
                let started = ProcessInfo.processInfo.systemUptime
                do {
                    guard let interface else {
                        throw NativeNetworkError.invalidInterface("unavailable")
                    }
                    let addresses = try await query(
                        interface: interface, server: server, host: host, type: 1,
                        deadline: min(deadline, Date().addingTimeInterval(2)))
                    results.append(
                        DNSDiagnosticQuery(
                            hostname: host, server: server, addresses: addresses,
                            elapsedMilliseconds: Int(
                                (ProcessInfo.processInfo.systemUptime - started) * 1000)))
                } catch {
                    let category = ConnectivityProbe.errorCategory(error)
                    if category == "request_timeout" { timeouts[server, default: 0] += 1 }
                    results.append(
                        DNSDiagnosticQuery(
                            hostname: host, server: server,
                            error: interface == nil ? "no_wifi_interface" : category,
                            elapsedMilliseconds: Int(
                                (ProcessInfo.processInfo.systemUptime - started) * 1000)))
                }
            }
        }
        let responding = Array(Set(results.filter { !($0.addresses ?? []).isEmpty }.map(\.server)))
            .sorted()
        return DNSDiagnosticMatrix(
            serversTried: servers, serversResponding: responding, queries: results,
            deadlineReached: Date() >= deadline || Task.isCancelled)
    }
    public static func isIPAddress(_ value: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }
}

import CuppaCore
import Darwin
import Foundation
import SystemConfiguration

public struct CommandOutput: Sendable {
    public var status: Int32
    public var text: String
    public var stderr: String = ""
    public var timedOut: Bool
    public init(status: Int32, text: String, timedOut: Bool = false) {
        self.status = status
        self.text = text
        self.timedOut = timedOut
    }
}
public protocol SystemCommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) async
        -> CommandOutput
}
public struct NativeSystemCommands: SystemCommandRunning {
    public init() {}
    public func run(_ executable: String, arguments: [String], timeout: TimeInterval = 5) async
        -> CommandOutput
    {
        do { return try await capture(executable, arguments: arguments, timeout: timeout) } catch {
            return CommandOutput(status: -1, text: "")
        }
    }

    /// Native bounded capture. Temporary files prevent pipe backpressure from blocking
    /// termination; stdin and both output streams never touch the user's shell.
    public func capture(
        _ executable: String, arguments: [String], timeout: TimeInterval = 5,
        stdin: Data? = nil, maximumOutputBytes: Int = 2_097_152
    ) async throws -> CommandOutput {
        guard executable.hasPrefix("/"), timeout.isFinite, timeout > 0,
            maximumOutputBytes >= 0, maximumOutputBytes <= 8_388_608
        else { throw NativeNetworkError.invalidRequest }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let out = directory.appendingPathComponent("stdout")
                    let err = directory.appendingPathComponent("stderr")
                    let input = directory.appendingPathComponent("stdin")
                    for file in [out, err] {
                        guard
                            FileManager.default.createFile(
                                atPath: file.path, contents: nil,
                                attributes: [.posixPermissions: 0o600])
                        else { throw CocoaError(.fileWriteUnknown) }
                    }
                    let outHandle = try FileHandle(forWritingTo: out)
                    let errHandle = try FileHandle(forWritingTo: err)
                    defer {
                        try? outHandle.close()
                        try? errHandle.close()
                    }
                    var inputHandle: FileHandle?
                    if let stdin {
                        try stdin.write(to: input)
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o600], ofItemAtPath: input.path)
                        inputHandle = try FileHandle(forReadingFrom: input)
                    }
                    defer { try? inputHandle?.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: executable)
                    process.arguments = arguments
                    process.standardOutput = outHandle
                    process.standardError = errHandle
                    process.standardInput = inputHandle ?? FileHandle.nullDevice
                    let done = DispatchSemaphore(value: 0)
                    process.terminationHandler = { _ in done.signal() }
                    try process.run()
                    let timedOut = done.wait(timeout: .now() + timeout) == .timedOut
                    if timedOut {
                        process.terminate()
                        if done.wait(timeout: .now() + 0.2) == .timedOut {
                            Darwin.kill(process.processIdentifier, SIGKILL)
                            _ = done.wait(timeout: .now() + 1)
                        }
                    }
                    // Foundation's termination handler runs after waitpid has reaped
                    // the child. waitUntilExit also synchronizes terminationStatus.
                    process.waitUntilExit()
                    func read(_ file: URL) throws -> String {
                        let handle = try FileHandle(forReadingFrom: file)
                        defer { try? handle.close() }
                        return String(
                            decoding: try handle.read(upToCount: maximumOutputBytes) ?? Data(),
                            as: UTF8.self)
                    }
                    var result = CommandOutput(
                        status: timedOut ? -1 : process.terminationStatus,
                        text: try read(out), timedOut: timedOut)
                    result.stderr = try read(err)
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
public struct CaptiveNetworkRecord: Sendable, Equatable {
    public let stage: String?
    public let waitingOnUI: Bool
    public init(stage: String? = nil, waitingOnUI: Bool = false) {
        self.stage = stage
        self.waitingOnUI = waitingOnUI
    }
    public var isCaptive: Bool {
        waitingOnUI
            || stage?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "websheet"
    }
}

public struct NativeNetworkInspector: NetworkInspecting {
    private let commands: any SystemCommandRunning
    private let statusReader: (@Sendable (String) -> CaptiveNetworkRecord?)?
    public init(
        commands: any SystemCommandRunning = NativeSystemCommands(),
        captiveStatus: (@Sendable (String) -> CaptiveNetworkRecord?)? = nil
    ) {
        self.commands = commands
        self.statusReader = captiveStatus
    }
    private func run(_ path: String, _ args: [String]) async -> String {
        let output = await commands.run(path, arguments: args, timeout: 5)
        return output.status == 0 && !output.timedOut ? output.text : ""
    }
    public static func field(_ name: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 && parts[0] == name && !parts[1].isEmpty { return parts[1] }
        }
        return nil
    }
    public static func wifiInterfaces(in text: String) -> [String] {
        var port = ""
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if let value = field("Hardware Port", in: line) { port = value.lowercased() }
            if port.contains("wi-fi") || port.contains("airport"),
                let device = field("Device", in: line)
            {
                result.append(device)
            }
        }
        return result
    }
    public static func canonicalMAC(_ text: String) -> String? {
        guard let range = text.range(of: " at ") else { return nil }
        let mac = text[range.upperBound...].split(separator: " ").first.map(String.init) ?? ""
        let parts = mac.split(separator: ":")
        guard parts.count == 6,
            parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && UInt8($0, radix: 16) != nil })
        else { return nil }
        return parts.map { String(format: "%02x", UInt8($0, radix: 16)!) }.joined(separator: ":")
    }
    public func current() async -> NetworkSnapshot {
        async let hardware = run("/usr/sbin/networksetup", ["-listallhardwareports"])
        async let defaultRoute = run("/sbin/route", ["-n", "get", "default"])
        let interfaces = Self.wifiInterfaces(in: await hardware)
        let route = await defaultRoute
        let preferred = Self.field("interface", in: route)
        var active: String?
        var address: String?
        if let preferred, interfaces.contains(preferred) { active = preferred }
        for interface in interfaces {
            let assigned = await run("/usr/sbin/ipconfig", ["getifaddr", interface])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !assigned.isEmpty && (active == nil || active == interface) {
                active = interface
                address = assigned
                break
            }
        }
        if active == nil {
            for interface in interfaces {
                let link = await run("/sbin/ifconfig", [interface])
                if Self.field("status", in: link) == "active", captiveRecord(interface) != nil {
                    active = interface
                    break
                }
            }
        }
        // Preserve the default non-Wi-Fi interface when Wi-Fi is disconnected;
        // the engine uses this positive evidence to stay dormant on Ethernet.
        if active == nil { active = preferred }
        guard let interface = active else { return NetworkSnapshot(wifiInterfaces: interfaces) }
        async let scopedRoute = run("/sbin/route", ["-n", "get", "-ifscope", interface, "default"])
        async let summary = run("/usr/sbin/ipconfig", ["getsummary", interface])
        async let packet = run("/usr/sbin/ipconfig", ["getpacket", interface])
        let gateway =
            Self.field("gateway", in: await scopedRoute)
            ?? (preferred == interface ? Self.field("gateway", in: route) : nil)
        var mac: String?
        if let gateway { mac = Self.canonicalMAC(await run("/usr/sbin/arp", ["-n", gateway])) }
        let ssid = Self.field("SSID", in: await summary)
        let record = captiveRecord(interface)
        return NetworkSnapshot(
            interface: interface, gatewayIP: gateway, gatewayMAC: mac,
            ssid: ssid == "<redacted>" ? nil : ssid,
            dhcpDomain: Self.field("domain_name (string)", in: await packet),
            wifiInterfaces: interfaces,
            captiveHint: record?.isCaptive ?? false,
            captiveStage: record?.stage, address: address)
    }
    private func captiveRecord(_ interface: String) -> CaptiveNetworkRecord? {
        if let statusReader { return statusReader(interface) }
        guard let store = SCDynamicStoreCreate(nil, "CuppaWiFi" as CFString, nil, nil),
            let dictionary = SCDynamicStoreCopyValue(
                store, "State:/Network/Interface/\(interface)/CaptiveNetwork" as CFString)
                as? [String: Any]
        else { return nil }
        let stage = dictionary["Stage"] as? String
        let waiting = dictionary["WaitingOnUI"] as? Bool
        guard stage != nil || waiting != nil else { return nil }
        return CaptiveNetworkRecord(stage: stage, waitingOnUI: waiting ?? false)
    }
}

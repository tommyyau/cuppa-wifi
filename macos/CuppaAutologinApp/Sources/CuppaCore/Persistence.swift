import Darwin
import Foundation

/// Stable v1-compatible locations. Shipping code is never loaded from this data directory.
public struct EnginePaths: Sendable {
    public let root: URL
    public let log: URL
    public init(
        root: URL? = nil, log: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let override = environment["WIFI_AUTOLOGIN_DATA_DIR"].flatMap {
            $0.isEmpty ? nil : $0
        }
        self.root =
            root ?? override.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".local/state/wifi-autologin")
        self.log = log ?? home.appendingPathComponent("Library/Logs/wifi-autologin.log")
    }
    public var state: URL { root.appendingPathComponent("state.json") }
    public var lock: URL { root.appendingPathComponent("wifi-autologin.lock") }
    public var identity: URL { root.appendingPathComponent("config/identity.env") }
    public var ignored: URL { root.appendingPathComponent("config/networks.ignore") }
    public var handoff: URL { root.appendingPathComponent("webview_handoff.json") }
    public var unsupported: URL { root.appendingPathComponent("webview_unsupported.json") }
    public var progress: URL { root.appendingPathComponent("portal_progress.json") }
    public var captures: URL { root.appendingPathComponent("captures") }
    public var forensics: URL { root.appendingPathComponent("forensics") }
    public var journeys: URL { root.appendingPathComponent("rendered-journeys") }
    public var learning: URL { root.appendingPathComponent("portal_learning.json") }
}

/// Copies legacy Persona bytes once. Never deletes the original or replaces a saved Persona.
public enum IdentityMigration {
    @discardableResult public static func copyIfNeeded(from source: URL, to target: URL) throws
        -> Bool
    {
        guard source.standardizedFileURL != target.standardizedFileURL,
            !FileManager.default.fileExists(atPath: target.path),
            FileManager.default.fileExists(atPath: source.path)
        else { return false }
        try PrivateFile.write(Data(contentsOf: source), to: target)
        return true
    }
}

public enum PrivateFile {
    public static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    /// Create the temporary file privately BEFORE writing sensitive bytes, then atomically rename.
    public static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temp)
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard Darwin.rename(temp.path, url.path) == 0 else { throw POSIXError(.EIO) }
    }
    public static func writeJSON(_ object: Any, to url: URL) throws {
        try write(
            JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            to: url)
    }
    public static func object(at url: URL, maximumBytes: Int = 1_048_576) -> [String: Any]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= maximumBytes,
            let data = try? Data(contentsOf: url),
            let value = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return value as? [String: Any]
    }
    public static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

/// Same cross-process advisory lock as v1; shared by launchd, UI checks and WebKit.
public final class EngineLock: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    public static func acquire(_ url: URL) -> EngineLock? {
        try? PrivateFile.directory(url.deletingLastPathComponent())
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return nil }
        _ = fchmod(fd, 0o600)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return EngineLock(fd)
    }
    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

public enum NetworkIdentity {
    public static func isSharedMAC(_ mac: String?) -> Bool {
        guard let parts = mac?.split(separator: ":"), parts.count == 6 else { return false }
        let bytes = parts.compactMap { UInt8($0, radix: 16) }
        guard bytes.count == 6 else { return false }
        return Array(bytes.prefix(5)) == [0, 0, 12, 7, 172]
            || (Array(bytes.prefix(4)) == [0, 0, 12, 159] && bytes[4] & 240 == 240)
            || Array(bytes.prefix(3)) == [0, 7, 180] || Array(bytes.prefix(5)) == [0, 0, 94, 0, 1]
    }
    public static func fingerprint(_ network: NetworkSnapshot, portalDomain: String? = nil)
        -> String?
    {
        (!isSharedMAC(network.gatewayMAC) ? network.gatewayMAC : nil) ?? portalDomain ?? network
            .ssid ?? network.dhcpDomain
    }
    public static func changed(from old: NetworkSnapshot, to new: NetworkSnapshot) -> Bool {
        func differs(_ a: String?, _ b: String?) -> Bool { a != nil && b != nil && a != b }
        return differs(old.gatewayMAC, new.gatewayMAC) || differs(old.ssid, new.ssid)
            || differs(old.dhcpDomain, new.dhcpDomain)
    }
    public static func sameConnection(_ a: NetworkSnapshot, _ b: NetworkSnapshot) -> Bool {
        a.interface == b.interface && a.gatewayIP == b.gatewayIP && a.gatewayMAC == b.gatewayMAC
            && !changed(from: a, to: b)
    }
    public static func isHotspot(_ address: String?) -> Bool {
        guard let address else { return false }
        if address == "192.168.43.1" { return true }
        let p = address.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && Array(p.prefix(3)) == [172, 20, 10] && (0...15).contains(p[3])
    }
    public static func dormancy(
        network: NetworkSnapshot, identity: PortalIdentity, ignoreText: String
    ) -> String? {
        if let interface = network.interface, !network.wifiInterfaces.isEmpty,
            !network.wifiInterfaces.contains(interface)
        {
            return "non_wifi"
        }
        let ignored = ignoreText.components(separatedBy: .newlines).map {
            $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces).lowercased()
        }
        if let mac = network.gatewayMAC, ignored.contains(mac.lowercased()) {
            return "ignored_gateway"
        }
        if identity.ignoreHotspots && isHotspot(network.gatewayIP) { return "personal_hotspot" }
        return nil
    }
}

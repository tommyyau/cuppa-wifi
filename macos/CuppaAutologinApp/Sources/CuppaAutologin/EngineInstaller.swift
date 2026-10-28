import CuppaCore
import Foundation

enum EngineInstallerError: LocalizedError {
    case resourcesMissing
    case installFailed(String)
    var errorDescription: String? {
        switch self {
        case .resourcesMissing: "The Cuppa Wi-Fi application resources are missing."
        case .installFailed(let message):
            "The background service could not be installed: \(message)"
        }
    }
}

/// Native launchd registration for the same signed executable as the menu-bar app.
/// Existing configuration is migrated once; no executable code is copied into user data.
enum EngineInstaller {
    static func syncBundledEngine(
        paths: EnginePaths = EnginePaths(), resources: URL = SystemPaths.resources,
        executable: URL? = Bundle.main.executableURL,
        legacyIdentity: URL = SystemPaths.legacyEngine.appendingPathComponent(
            "config/identity.env"),
        launchAgent: URL = SystemPaths.launchAgent
    ) throws -> Bool {
        guard let executable,
            FileManager.default.fileExists(
                atPath: resources.appendingPathComponent("portal-schema.json").path)
        else { throw EngineInstallerError.resourcesMissing }
        try PrivateFile.directory(paths.root)
        if !FileManager.default.fileExists(atPath: paths.identity.path) {
            if try !IdentityMigration.copyIfNeeded(from: legacyIdentity, to: paths.identity) {
                try IdentityStore.save(FakeIdentity.generated(), to: paths.identity)
            }
        }
        guard let data = try? Data(contentsOf: launchAgent),
            let value = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let args = value["ProgramArguments"] as? [String]
        else { return true }
        return args != [executable.path, "--engine-once"]
    }

    static func servicePropertyList(executable: URL, interval: MonitoringInterval, log: URL)
        -> [String: Any]
    {
        [
            "Label": SystemPaths.serviceLabel,
            "AssociatedBundleIdentifiers": ["io.github.tommyyau.wifi-autologin"],
            "ProgramArguments": [executable.path, "--engine-once"],
            "RunAtLoad": true, "StartInterval": interval.rawValue, "ThrottleInterval": 10,
            "WatchPaths": ["/Library/Preferences/SystemConfiguration"],
            "StandardOutPath": log.path, "StandardErrorPath": log.path,
        ]
    }

    static func installService(
        interval: MonitoringInterval,
        executable: URL? = Bundle.main.executableURL,
        launchAgent: URL = SystemPaths.launchAgent,
        log: URL = SystemPaths.logFile,
        run: (String, [String], TimeInterval) -> ProcessResult = {
            ProcessRunner.run($0, $1, timeout: $2)
        }
    ) throws {
        guard let executable else { throw EngineInstallerError.resourcesMissing }
        let desired = servicePropertyList(executable: executable, interval: interval, log: log)
        let previousData = try? Data(contentsOf: launchAgent)
        let existing = previousData.flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let domain = "gui/\(getuid())"
        let loaded =
            run("/bin/launchctl", ["print", domain + "/" + SystemPaths.serviceLabel], 5).status == 0
        // bootstrap does not clear launchd's persistent disabled override.
        // Installing monitoring is an explicit request to enable this service.
        let enabled = run(
            "/bin/launchctl", ["enable", domain + "/" + SystemPaths.serviceLabel], 5)
        guard enabled.status == 0 else {
            throw EngineInstallerError.installFailed(
                enabled.error.isEmpty ? enabled.output : enabled.error)
        }
        if let existing, NSDictionary(dictionary: existing).isEqual(to: desired), loaded { return }
        let data = try PropertyListSerialization.data(
            fromPropertyList: desired, format: .xml, options: 0)
        if !FileManager.default.fileExists(atPath: log.path) {
            try PrivateFile.write(Data(), to: log)
        }
        if loaded {
            let result = run("/bin/launchctl", ["bootout", domain, launchAgent.path], 10)
            guard result.status == 0 else {
                throw EngineInstallerError.installFailed(
                    "The previous service could not be stopped.")
            }
        }
        do {
            try PrivateFile.write(data, to: launchAgent)
            let result = run("/bin/launchctl", ["bootstrap", domain, launchAgent.path], 15)
            guard result.status == 0 else {
                throw EngineInstallerError.installFailed(
                    result.error.isEmpty ? result.output : result.error)
            }
        } catch {
            // Preserve the old service and its cadence if migration cannot start.
            // User data and Persona are never part of this replacement.
            if let previousData {
                try PrivateFile.write(previousData, to: launchAgent)
            } else {
                PrivateFile.remove(launchAgent)
            }
            if loaded {
                let restored = run("/bin/launchctl", ["bootstrap", domain, launchAgent.path], 15)
                guard restored.status == 0 else {
                    throw EngineInstallerError.installFailed(
                        "The previous service definition was restored, but monitoring could not restart. Restart monitoring in Settings."
                    )
                }
            }
            throw error
        }
    }
}

/// Service transactions, including rollback, share a dedicated serial queue.
final class EngineServiceOperations: @unchecked Sendable {
    typealias Runner = @Sendable (String, [String], TimeInterval) -> ProcessResult
    private let queue = DispatchQueue(label: "CuppaWiFi.engine-service")
    private let sync: @Sendable () throws -> Bool
    private let install: @Sendable (MonitoringInterval) throws -> Void
    private let runner: Runner
    init(sync: @escaping @Sendable () throws -> Bool = { try EngineInstaller.syncBundledEngine() },
         install: @escaping @Sendable (MonitoringInterval) throws -> Void = { try EngineInstaller.installService(interval: $0) },
         runner: @escaping Runner = { ProcessRunner.run($0, $1, timeout: $2) }) {
        self.sync = sync
        self.install = install
        self.runner = runner
    }
    private func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func syncBundledEngine() async throws -> Bool { try await perform(sync) }
    func installService(interval: MonitoringInterval) async throws {
        try await perform { [install] in try install(interval) }
    }
    func unloadService() async -> ProcessResult {
        try! await perform { [runner] in
            runner("/bin/launchctl", ["bootout", "gui/\(getuid())", SystemPaths.launchAgent.path], 10)
        }
    }
    func queryServiceLoaded() async -> Bool {
        try! await perform { [runner] in
            runner("/bin/launchctl", ["print", "gui/\(getuid())/\(SystemPaths.serviceLabel)"], 3).status == 0
        }
    }
}

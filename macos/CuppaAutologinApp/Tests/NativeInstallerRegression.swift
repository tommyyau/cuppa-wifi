import CuppaCore
import Foundation

private final class SyntheticLaunchctl {
    var calls: [[String]] = []
    var loaded = false
    var disabled = true
    var failEnable = false
    var failBootout = false
    var failBootstrap = false
    var failEveryBootstrap = false
    var bootstrapContents: [Data] = []
    func run(_ executable: String, _ arguments: [String], _ timeout: TimeInterval) -> ProcessResult
    {
        precondition(executable == "/bin/launchctl")
        precondition([5, 10, 15].contains(timeout))
        calls.append(arguments)
        switch arguments.first {
        case "print": return ProcessResult(status: loaded ? 0 : 1, output: "", error: "")
        case "bootout":
            return ProcessResult(
                status: failBootout ? 1 : 0, output: "", error: "synthetic bootout error")
        case "enable":
            if !failEnable { disabled = false }
            return ProcessResult(status: failEnable ? 1 : 0, output: "", error: "synthetic enable error")
        case "bootstrap":
            if let path = arguments.last,
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            {
                bootstrapContents.append(data)
            }
            let fail = disabled || failBootstrap || failEveryBootstrap
            failBootstrap = false
            return ProcessResult(
                status: fail ? 1 : 0, output: "", error: fail ? "synthetic bootstrap error" : "")
        default: preconditionFailure("Unexpected synthetic launchctl operation")
        }
    }
}

@main
enum NativeInstallerRegression {
    static func main() throws {
        try testFirstRunAndLegacyPersonaMigration()
        try testExecutableRenameMigration()
        let executable = URL(
            fileURLWithPath: "/Applications/Cuppa Wi-Fi.app/Contents/MacOS/CuppaAutologin")
        for interval in MonitoringInterval.allCases {
            let record = EngineInstaller.servicePropertyList(
                executable: executable, interval: interval,
                log: URL(fileURLWithPath: "/tmp/synthetic-cuppa.log"))
            let data = try PropertyListSerialization.data(
                fromPropertyList: record, format: .xml, options: 0)
            let decoded =
                try PropertyListSerialization.propertyList(from: data, format: nil)
                as! [String: Any]
            precondition(decoded["StartInterval"] as? Int == interval.rawValue)
            precondition(
                decoded["ProgramArguments"] as? [String] == [executable.path, "--engine-once"])
            precondition(
                decoded["AssociatedBundleIdentifiers"] as? [String] == [
                    "io.github.tommyyau.wifi-autologin"
                ])
            precondition(decoded["RunAtLoad"] as? Bool == true)
            precondition(
                decoded["WatchPaths"] as? [String] == ["/Library/Preferences/SystemConfiguration"])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-independent-installer-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("LaunchAgents/service.plist")
        let log = root.appendingPathComponent("logs/engine.log")
        let simulator = SyntheticLaunchctl()
        func install(_ interval: MonitoringInterval = .thirtySeconds) throws {
            try EngineInstaller.installService(
                interval: interval, executable: executable, launchAgent: agent, log: log,
                run: simulator.run)
        }
        func mustThrow(_ operation: () throws -> Void) {
            var rejected = false
            do { try operation() } catch { rejected = true }
            precondition(rejected, "Expected synthetic installation failure")
        }
        // A persistent disabled override must be cleared before bootstrap.
        try install()
        precondition(simulator.calls.map { $0[0] } == ["print", "enable", "bootstrap"])
        for item in [agent, log] {
            let mode =
                try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions]
                as! NSNumber
            precondition(mode.intValue == 0o600)
        }
        for item in [agent.deletingLastPathComponent(), log.deletingLastPathComponent()] {
            let mode =
                try FileManager.default.attributesOfItem(atPath: item.path)[.posixPermissions]
                as! NSNumber
            precondition(mode.intValue == 0o700)
        }
        precondition(!simulator.disabled)
        precondition(simulator.calls[1] == ["enable", "gui/\(getuid())/" + SystemPaths.serviceLabel])
        let initial = try Data(contentsOf: agent)
        simulator.calls = []
        simulator.failEnable = true
        mustThrow { try install() }
        precondition(simulator.calls.map { $0[0] } == ["print", "enable"])
        let afterEnableFailure = try Data(contentsOf: agent)
        precondition(afterEnableFailure == initial)
        simulator.failEnable = false
        simulator.calls = []
        simulator.loaded = true
        try install()
        precondition(simulator.calls.map { $0[0] } == ["print", "enable"])
        let idempotent = try Data(contentsOf: agent)
        precondition(idempotent == initial)
        // Loaded legacy service is restored byte-for-byte and bootstrapped after migration fails.
        let legacy = Data(
            "<plist version='1.0'><dict><key>ProgramArguments</key><array><string>/synthetic/old/python</string></array><key>StartInterval</key><integer>120</integer></dict></plist>"
                .utf8)
        try PrivateFile.write(legacy, to: agent)
        simulator.calls = []
        simulator.bootstrapContents = []
        simulator.failBootstrap = true
        mustThrow { try install(.oneMinute) }
        precondition(
            simulator.calls.map { $0[0] } == ["print", "enable", "bootout", "bootstrap", "bootstrap"])
        let restored1 = try Data(contentsOf: agent)
        precondition(restored1 == legacy)
        precondition(
            simulator.bootstrapContents.count == 2 && simulator.bootstrapContents.last == legacy)
        // If rollback also fails, report stopped monitoring honestly and preserve its definition.
        simulator.calls = []
        simulator.failEveryBootstrap = true
        do {
            try install(.oneMinute)
            preconditionFailure("Expected replacement and rollback bootstrap failures")
        } catch {
            precondition(error.localizedDescription.contains("monitoring could not restart"))
        }
        let doubleFailure = try Data(contentsOf: agent)
        precondition(doubleFailure == legacy)
        precondition(
            simulator.calls.map { $0[0] } == ["print", "enable", "bootout", "bootstrap", "bootstrap"])
        simulator.failEveryBootstrap = false
        // Failed bootout leaves the original plist untouched and never starts replacement.
        simulator.calls = []
        simulator.failBootout = true
        mustThrow { try install() }
        precondition(simulator.calls.map { $0[0] } == ["print", "enable", "bootout"])
        let restored2 = try Data(contentsOf: agent)
        precondition(restored2 == legacy)
        // Unloaded legacy file rolls back without trying to start an absent old service.
        simulator.calls = []
        simulator.loaded = false
        simulator.failBootout = false
        simulator.failBootstrap = true
        mustThrow { try install() }
        precondition(simulator.calls.map { $0[0] } == ["print", "enable", "bootstrap"])
        let restored3 = try Data(contentsOf: agent)
        precondition(restored3 == legacy)
        // A failed first install removes its new plist instead of leaving a broken registration.
        try FileManager.default.removeItem(at: agent)
        simulator.calls = []
        simulator.failBootstrap = true
        mustThrow { try install() }
        precondition(!FileManager.default.fileExists(atPath: agent.path))
        // Missing executable fails before even querying launchctl.
        simulator.calls = []
        mustThrow {
            try EngineInstaller.installService(
                interval: .oneMinute, executable: nil, launchAgent: agent, log: log,
                run: simulator.run)
        }
        precondition(simulator.calls.isEmpty)
        let outside = root.appendingPathComponent("unrelated.plist")
        try PrivateFile.write(legacy, to: outside)
        try FileManager.default.createSymbolicLink(at: agent, withDestinationURL: outside)
        simulator.calls = []
        try install()
        let external = try Data(contentsOf: outside)
        precondition(external == legacy)
        precondition(simulator.calls.map { $0[0] } == ["print", "enable", "bootstrap"])
        precondition(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: agent.path)) == nil)
        print(
            "Native LaunchAgent interval, private file, idempotence and rollback tests: PASS (11 service scenarios plus 7 Persona migration scenarios)"
        )
    }

    static func testExecutableRenameMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-executable-rename-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = EnginePaths(
            root: root.appendingPathComponent("data"),
            log: root.appendingPathComponent("engine.log"))
        let agent = root.appendingPathComponent("service.plist")
        let resources = root.appendingPathComponent("resources")
        let oldExecutable = URL(
            fileURLWithPath: "/Applications/Cuppa Wi-Fi.app/Contents/MacOS/WiFiAutologin")
        let newExecutable = URL(
            fileURLWithPath: "/Applications/Cuppa Wi-Fi.app/Contents/MacOS/CuppaAutologin")
        let identity = Data("FAKE_FIRST_NAME=Preserved\n".utf8)
        try PrivateFile.write(identity, to: paths.identity)
        try PrivateFile.write(
            Data("{}".utf8), to: resources.appendingPathComponent("portal-schema.json"))
        let previous = EngineInstaller.servicePropertyList(
            executable: oldExecutable, interval: .twoMinutes, log: paths.log)
        try PrivateFile.write(
            PropertyListSerialization.data(fromPropertyList: previous, format: .xml, options: 0),
            to: agent)
        let needsMigration = try EngineInstaller.syncBundledEngine(
            paths: paths, resources: resources, executable: newExecutable,
            legacyIdentity: root.appendingPathComponent("missing.env"), launchAgent: agent)
        precondition(needsMigration)
        let simulator = SyntheticLaunchctl()
        simulator.loaded = true
        try EngineInstaller.installService(
            interval: .twoMinutes, executable: newExecutable, launchAgent: agent, log: paths.log,
            run: simulator.run)
        precondition(simulator.calls.map { $0[0] } == ["print", "enable", "bootout", "bootstrap"])
        let actual =
            try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil)
            as! [String: Any]
        precondition(
            actual["ProgramArguments"] as? [String] == [newExecutable.path, "--engine-once"])
        precondition(actual["Label"] as? String == SystemPaths.serviceLabel)
        precondition(actual["StartInterval"] as? Int == 120)
        let preserved = try Data(contentsOf: paths.identity)
        precondition(preserved == identity)
        let current = try EngineInstaller.syncBundledEngine(
            paths: paths, resources: resources, executable: newExecutable,
            legacyIdentity: root.appendingPathComponent("missing.env"), launchAgent: agent)
        precondition(!current)
    }

    static func testFirstRunAndLegacyPersonaMigration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cuppa-migrate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = EnginePaths(root: root.appendingPathComponent("data"))
        let resources = root.appendingPathComponent("resources")
        let legacy = root.appendingPathComponent("legacy/config/identity.env")
        let agent = root.appendingPathComponent("service.plist")
        let executable = root.appendingPathComponent("Cuppa.app/Contents/MacOS/CuppaAutologin")
        func sync(_ binary: URL? = executable) throws -> Bool {
            try EngineInstaller.syncBundledEngine(
                paths: paths, resources: resources, executable: binary, legacyIdentity: legacy,
                launchAgent: agent)
        }
        var rejected = false
        do { _ = try sync() } catch { rejected = true }
        precondition(rejected && !FileManager.default.fileExists(atPath: paths.root.path))
        try PrivateFile.write(
            Data("{}".utf8), to: resources.appendingPathComponent("portal-schema.json"))
        rejected = false
        do { _ = try sync(nil) } catch { rejected = true }
        precondition(rejected && !FileManager.default.fileExists(atPath: paths.root.path))
        // Fresh install creates a complete private Persona without legacy files.
        let needsInstall = try sync()
        precondition(needsInstall)
        let fresh = try PortalIdentity.load(from: paths.identity)
        precondition(!fresh.email.isEmpty && !fresh.password.isEmpty)
        let freshData = try Data(contentsOf: paths.identity)
        let permissions =
            try FileManager.default.attributesOfItem(atPath: paths.identity.path)[.posixPermissions]
            as! NSNumber
        precondition(permissions.intValue == 0o600)
        // Existing data wins over an available legacy Persona.
        let old = Data("FAKE_FIRST_NAME=Legacy\n".utf8)
        try PrivateFile.write(old, to: legacy)
        _ = try sync()
        let existing = try Data(contentsOf: paths.identity)
        precondition(existing == freshData)
        // The same production installer migrates exact bytes when shared data is absent.
        try FileManager.default.removeItem(at: paths.identity)
        _ = try sync()
        let migrated = try Data(contentsOf: paths.identity)
        let original = try Data(contentsOf: legacy)
        precondition(migrated == old && original == old)
        // Native service definitions are recognized; malformed definitions require reinstall.
        let record = EngineInstaller.servicePropertyList(
            executable: executable, interval: .oneMinute, log: paths.log)
        try PrivateFile.write(
            PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0),
            to: agent)
        let current = try sync()
        precondition(!current)
        try PrivateFile.write(Data("malformed".utf8), to: agent)
        let malformed = try sync()
        precondition(malformed)
    }
}

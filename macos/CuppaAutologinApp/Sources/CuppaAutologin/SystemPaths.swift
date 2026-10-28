import Foundation

enum SystemPaths {
    // Stable upgrade identifiers preserve existing preferences, permissions,
    // monitoring registration and saved data across the Cuppa module rename.
    static let serviceLabel = "com.tommyyau.wifi-autologin"
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let stateDirectory = home
        .appendingPathComponent(".local/state/wifi-autologin", isDirectory: true)
    static var stateFile: URL { sharedDataDirectory().appendingPathComponent("state.json") }
    static var engineLock: URL {
        sharedDataDirectory().appendingPathComponent("wifi-autologin.lock")
    }
    static var webViewHandoff: URL {
        sharedDataDirectory().appendingPathComponent("webview_handoff.json")
    }
    static var portalProgress: URL {
        sharedDataDirectory().appendingPathComponent("portal_progress.json")
    }
    static let logFile = home
        .appendingPathComponent("Library/Logs/wifi-autologin.log")
    static let launchAgent = home.appendingPathComponent(
        "Library/LaunchAgents/\(serviceLabel).plist"
    )
    private static let legacyApplicationSupport = home.appendingPathComponent(
        "Library/Application Support/WiFi Autologin",
        isDirectory: true
    )
    static let legacyEngine = legacyApplicationSupport.appendingPathComponent(
        "Engine",
        isDirectory: true
    )
    static let resources = Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    static var installedCaptures: URL { sharedDataDirectory().appendingPathComponent("captures", isDirectory: true) }

    /// One shared directory for the GUI, background checks and browser handoffs.
    /// Explicit environment overrides isolate development/tests; the normal
    /// per-user location remains compatible with v1.
    static func sharedDataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["WIFI_AUTOLOGIN_DATA_DIR"],
           !override.isEmpty
        {
            let expanded = (override as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true)
        }
        return stateDirectory
    }

    /// Shared Persona path used by both the GUI and native background checks.
    /// It preserves the existing v1 configuration during upgrades.
    static func sharedIdentityFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        sharedDataDirectory(environment: environment)
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("identity.env")
    }
}

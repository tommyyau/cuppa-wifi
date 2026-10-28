import CuppaCore
import Foundation

/// Diagnostic history never authorizes replacing the configured Persona phone.
public struct PhonePolicyStore: Sendable {
    public let path: URL
    public init(path: URL) { self.path = path }
    public func knows(_ key: String) -> Bool {
        !key.isEmpty
            && ((PrivateFile.object(at: path)?["phone_validating_venues"] as? [String]) ?? [])
                .contains(key)
    }
    @discardableResult public func remember(_ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        var value = PrivateFile.object(at: path) ?? [:]
        var venues = value["phone_validating_venues"] as? [String] ?? []
        guard !venues.contains(key) else { return false }
        venues.append(key)
        value["phone_validating_venues"] = venues.sorted()
        do {
            try PrivateFile.writeJSON(value, to: path)
            return true
        } catch { return false }
    }
}

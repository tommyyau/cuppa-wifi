import CuppaNetworking
import Foundation

public struct NativeNetworkRecovery: Sendable {
    public static func gatewayURL(_ address: String?) -> URL? {
        guard let address, ScopedDNSResolver.isIPAddress(address) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = address.contains(":") ? "[\(address)]" : address
        components.path = "/"
        return components.url
    }
    private let commands: any SystemCommandRunning
    private let sleep: @Sendable (Double) async -> Void
    public init(
        commands: any SystemCommandRunning = NativeSystemCommands(),
        sleep: @escaping @Sendable (Double) async -> Void = {
            try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        }
    ) {
        self.commands = commands
        self.sleep = sleep
    }
    public func reassociate(_ interface: String) async {
        guard interface.range(of: "^[a-zA-Z][a-zA-Z0-9]{0,15}$", options: .regularExpression) != nil
        else { return }
        _ = await commands.run(
            "/usr/sbin/networksetup", arguments: ["-setairportpower", interface, "off"], timeout: 10
        )
        await sleep(3)
        _ = await commands.run(
            "/usr/sbin/networksetup", arguments: ["-setairportpower", interface, "on"], timeout: 10)
    }
}

import CuppaCore
import CuppaNetworking
import Foundation
import Network
import WebKit

/// Thin WebKit adapter over the native, authenticated interface-scoped relay.
/// TLS stays between WebKit and the portal; no system proxy setting is changed.
@MainActor
final class PortalBrowserTransport {
    typealias Resolver = @Sendable (String, Date) async throws -> [String]
    private var relay: BrowserRelay?
    private var configuration: BrowserRelayConfiguration?
    var connectionCount: Int { relay?.connections ?? 0 }
    private(set) var port: UInt16?

    func start(
        interface: String, portalURL: URL, gatewayIP: String? = nil, resolver: Resolver? = nil
    ) async throws {
        let relay = try BrowserRelay(
            network: NetworkSnapshot(interface: interface, gatewayIP: gatewayIP),
            portalURL: portalURL, resolveHost: resolver)
        self.relay = relay
        let configuration = try await relay.start()
        self.configuration = configuration
        port = configuration.port
    }

    @available(macOS 14.0, *)
    func configure(_ store: WKWebsiteDataStore) {
        guard let configuration else { return }
        var proxy = ProxyConfiguration(
            httpCONNECTProxy: .hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: configuration.port)!),
            tlsOptions: nil)
        proxy.applyCredential(username: configuration.username, password: configuration.password)
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
    }

    func stop() {
        if let relay { Task { await relay.stop() } }
        relay = nil
        configuration = nil
        port = nil
    }
    deinit {
        if let relay { Task { await relay.stop() } }
    }
}

import CuppaCore
import CuppaNetworking
import Foundation

public struct EngineCommandResult: Sendable {
    public var status: Int32
    public var output: String
    public var error: String
    public init(status: Int32, output: String = "", error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }
}

/// One compiled runtime serves both in-process UI requests and launchd invocations.
public enum EngineCLI {
    public static func isEngineCommand(_ arguments: [String]) -> Bool {
        arguments.contains {
            [
                "--engine-once", "--once", "--status", "--portal-stats", "--webview-complete",
                "--webview-unsupported", "--install-check", "--ignore-current", "--ignored",
                "--triage", "--forensics", "--engine-help",
            ].contains($0)
        }
    }
    public static func execute(
        arguments: [String], paths: EnginePaths = EnginePaths(), resources: URL,
        inspector: any NetworkInspecting = NativeNetworkInspector()
    ) async -> EngineCommandResult {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
                !arguments[index + 1].hasPrefix("--")
            else { return nil }
            return arguments[index + 1]
        }
        func json(_ value: Any) -> String {
            (try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys])).flatMap {
                    String(data: $0, encoding: .utf8)
                } ?? "{}"
        }
        if arguments.contains("--engine-help") {
            return .init(
                status: 0,
                output:
                    "Cuppa Wi-Fi v2 native engine\n--once | --status | --portal-stats | --triage [venue] | --forensics | --ignore-current [label] | --ignored | --install-check\n"
            )
        }
        if arguments.contains("--status") {
            return .init(status: 0, output: json(EngineState.load(paths).fields))
        }
        if arguments.contains("--portal-stats") {
            return .init(status: 0, output: json(EvidenceStore(paths: paths).summary()))
        }
        if arguments.contains("--install-check") {
            do {
                _ = try PortalIdentity.load(from: paths.identity)
                try PrivateFile.directory(paths.root)
                return .init(
                    status: 0, output: "Native Swift engine ready; saved Persona is valid.")
            } catch { return .init(status: 1, error: "The saved Persona is missing or invalid.") }
        }
        if arguments.contains("--ignored") {
            return .init(
                status: 0,
                output: (try? String(contentsOf: paths.ignored, encoding: .utf8))
                    ?? "No ignored networks.")
        }
        if arguments.contains("--ignore-current") {
            let network = await inspector.current()
            guard let mac = network.gatewayMAC else {
                return .init(status: 1, error: "No gateway is available.")
            }
            let old = (try? String(contentsOf: paths.ignored, encoding: .utf8)) ?? ""
            let listed = old.components(separatedBy: .newlines).contains {
                $0.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces).lowercased()
                    == mac.lowercased()
            }
            if !listed {
                let label = (value("--ignore-current") ?? network.ssid ?? "Ignored network")
                    .components(separatedBy: .newlines).joined(separator: " ")
                do {
                    try PrivateFile.write(
                        Data(
                            (old + (old.hasSuffix("\n") || old.isEmpty ? "" : "\n")
                                + "\(mac)  # \(label)\n").utf8), to: paths.ignored)
                } catch { return .init(status: 1, error: "Could not save ignored network.") }
            }
            return .init(status: 0, output: "Network is ignored.")
        }
        if arguments.contains("--triage") {
            return .init(
                status: 0, output: TriageReport(paths: paths).render(selector: value("--triage")))
        }
        if arguments.contains("--forensics") {
            let network = await inspector.current()
            let recorder = ForensicRecorder(paths: paths)
            if let url = await recorder.run(
                network: network, client: NativeHTTPClient(network: network), trigger: "manual")
            {
                return .init(status: 0, output: url.path)
            }
            return .init(status: 1, error: "Could not save network diagnostics.")
        }
        let engine = CuppaEngine(paths: paths, resources: resources)
        let report = value("--webview-report").map { URL(fileURLWithPath: $0) }
        if arguments.contains("--webview-complete") {
            let result = await engine.completeBrowser(
                fingerprint: value("--webview-fingerprint"), venue: value("--webview-venue"),
                report: report, assisted: arguments.contains("--webview-assisted"))
            return .init(
                status: result,
                output: result == 0 ? "{\"status\":\"online\"}" : "{\"status\":\"captive\"}",
                error: result == 0 ? "" : "Internet access could not be verified for this network.")
        }
        if let reason = value("--webview-unsupported") {
            return .init(
                status: await engine.markUnsupported(
                    reason: reason, fingerprint: value("--webview-fingerprint"), report: report))
        }
        if arguments.contains("--once") || arguments.contains("--engine-once") {
            let result = await engine.once()
            return .init(
                status: result,
                error: result == 0 ? "" : "The connection check failed. See the local activity log."
            )
        }
        return .init(status: 2, error: "Unknown engine command. Use --engine-help.")
    }
}

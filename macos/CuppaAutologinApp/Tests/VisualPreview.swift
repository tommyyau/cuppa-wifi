import AppKit
import CuppaNetworking
import SwiftUI

@main
@MainActor
enum VisualPreview {
    static func main() throws {
        _ = NSApplication.shared
        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments.dropFirst().first
                ?? "/tmp/wifi-autologin-ui-previews",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let model = StatusModel()
        let activity = sampleActivity()
        let speed = SpeedMeasurement(
            downloadMbps: 38,
            uploadMbps: 9.4,
            latencyMilliseconds: 24,
            measuredAt: Date(),
            gatewayMac: "02:00:00:00:00:05",
            responsivenessRpm: 180
        )

        for (name, result) in [
            ("status-online", "ONLINE"),
            ("status-signing-in", "CAPTIVE"),
            ("status-offline", "NO_NETWORK"),
        ] {
            model.configureForVisualPreview(
                state: sampleState(lastResult: result),
                serviceLoaded: true,
                activity: activity,
                speedMeasurement: speed,
                activeOperation:
                    result == "CAPTIVE" ? .handlingPortal : nil
            )
            model.selectTab(.status)
            try render(
                PopoverRootView(model: model),
                to: outputDirectory.appendingPathComponent("\(name).png")
            )
        }

        var networkState = sampleState(lastResult: "NO_NETWORK")
        networkState.lastCheckTimestamp = Date().addingTimeInterval(-5).timeIntervalSince1970
        networkState.networkDiagnostic = NetworkDiagnostic(reason: "network_path_unavailable", title: "Likely network problem",
            detail: "Repeated gateway and external checks received no usable response. No portal is reachable for automatic sign-in. Try another network or ask the venue; filtering can cause the same symptoms.",
            checks: "gateway_ping=no_reply; gateway_http=timeout; direct_http=timeout", repeated: true,
            addressAssigned: true, consecutiveChecks: 2, checkedAt: Date().timeIntervalSince1970)
        var networkProgress = PortalDiagnostics(startedAt: Date().addingTimeInterval(-20).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, phase: "network_unavailable", title: "Likely network problem", terminal: true,
            reason: "network_path_unavailable", detail: networkState.networkDiagnostic?.detail)
        for (name, live) in [("activity-network-checking", true), ("activity-network-unavailable", false)] {
            networkProgress.phase = live ? "network_check" : "network_unavailable"
            networkProgress.terminal = !live
            networkProgress.title = live ? "Looking for a portal without DNS" : "Likely network problem"
            networkProgress.detail = live ? "Checking the gateway and a direct IP address for a captive redirect. No form has been submitted." : networkState.networkDiagnostic?.detail
            model.configureForVisualPreview(state: networkState, serviceLoaded: true,
                diagnostics: [DiagnosticAttempt(id: "network", steps: [
                    DiagnosticStep(attempt: "network", phase: "network_check", title: "Internet probes did not respond", detail: "Apple and Google DNS requests timed out.", status: "warn"),
                    DiagnosticStep(attempt: "network", phase: "network_check", title: "Checking the Wi-Fi gateway", detail: "Testing the local router.", status: "running"),
                    DiagnosticStep(attempt: "network", phase: live ? "network_check" : "outcome", title: networkProgress.title, detail: networkProgress.detail ?? "", status: live ? "running" : "stopped")
                ])], portalDiagnostics: networkProgress)
            model.selectTab(.activity)
            try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent(name + ".png"))
        }
        model.selectTab(.status)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("status-network-unavailable.png"))

        let proxySummary = NetworkDiagnostics.summary(["reason": "proxy_interference"])
        var proxyState = sampleState(lastResult: "NO_NETWORK")
        proxyState.networkDiagnostic = NetworkDiagnostic(
            reason: "proxy_interference", title: proxySummary.0, detail: proxySummary.1,
            checks: "probes=apple:proxy_detected,gstatic:proxy_detected", repeated: false,
            addressAssigned: true, consecutiveChecks: 1, checkedAt: Date().timeIntervalSince1970)
        let proxyProgress = PortalDiagnostics(
            startedAt: Date().addingTimeInterval(-5).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, phase: "network_unavailable",
            title: proxySummary.0, terminal: true, reason: "proxy_interference", detail: proxySummary.1)
        model.configureForVisualPreview(state: proxyState, serviceLoaded: true,
            portalDiagnostics: proxyProgress)
        for tab in [AppTab.status, .activity] {
            model.selectTab(tab)
            try render(PopoverRootView(model: model),
                to: outputDirectory.appendingPathComponent("\(tab.rawValue)-proxy-interference.png"))
        }

        let unavailable = PortalDiagnostics(startedAt: Date().addingTimeInterval(-10).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, phase: "stopped", title: "Wi-Fi sign-in page unavailable", terminal: true,
            reason: "portal_page_unavailable", detail: ActivityLog.attentionDetail(for: "portal_page_unavailable"), failureCode: 404)
        model.configureForVisualPreview(state: sampleState(lastResult: "UNSUPPORTED"), serviceLoaded: true,
            diagnostics: [DiagnosticAttempt(id: "unavailable", steps: [
                DiagnosticStep(attempt: "unavailable", phase: "page", title: "Portal returned HTTP 404", detail: "The configured sign-in page redirected to an error page with a website search form.", status: "warn"),
                DiagnosticStep(attempt: "unavailable", phase: "outcome", title: unavailable.title, detail: unavailable.detail ?? "", status: "stopped")
            ])], portalDiagnostics: unavailable)
        for tab in [AppTab.status, .activity] {
            model.selectTab(tab)
            try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("\(tab.rawValue)-portal-unavailable.png"))
        }

        var retryState = sampleState(lastResult: "CAPTIVE")
        retryState.consecutiveFailures = 1
        model.configureForVisualPreview(
            state: retryState,
            serviceLoaded: true,
            activity: activity,
            speedMeasurement: speed,
            portalAttemptNeedsRetry: true
        )
        model.selectTab(.status)
        try render(
            PopoverRootView(model: model),
            to: outputDirectory.appendingPathComponent(
                "status-retry-ready.png"
            )
        )

        model.configureForVisualPreview(state: sampleState(lastResult: "UNSUPPORTED"), serviceLoaded: true, activity: activity, speedMeasurement: speed, canFinishPortal: true)
        model.selectTab(.status)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("status-manual-sign-in.png"))

        model.configureForVisualPreview(
            state: sampleState(lastResult: "ONLINE"),
            serviceLoaded: true,
            activity: activity,
            speedMeasurement: speed
        )
        model.configureForVisualPreview(
            state: sampleState(lastResult: "ONLINE"), serviceLoaded: true, activity: activity,
            diagnostics: [DiagnosticAttempt(id: "preview", steps: [
                DiagnosticStep(attempt: "preview", phase: "network", title: "Connected to Wi-Fi", detail: "SSID: Caffe Nero", status: "ok"),
                DiagnosticStep(attempt: "preview", phase: "portal", title: "Captive portal detected", detail: "portal.example", status: "ok"),
                DiagnosticStep(attempt: "preview", phase: "form", title: "Prepared form", detail: "3 fields; 1 checkbox; submit button found", status: "ok", fields: [DiagnosticField(name: "email", label: "Email address", placeholder: "Email", type: "email", intent: "email", source: "Swift heuristic", category: "Persona email", maskedValue: "[masked]")]),
                DiagnosticStep(attempt: "preview", phase: "probe", title: "Probe: ONLINE", detail: "Internet access verified", status: "ok")
            ])], speedMeasurement: speed
        )
        for tab in [
            AppTab.activity,
            .persona,
            .settings,
            .help,
        ] {
            model.selectTab(tab)
            try render(
                PopoverRootView(model: model),
                to: outputDirectory.appendingPathComponent(
                    "\(tab.rawValue).png"
                )
            )
        }

        // Render a queued service transaction synchronously, before its task
        // runs. Inject no-op operations so previews can never touch launchd.
        let busyModel = StatusModel(serviceOperations: EngineServiceOperations(sync: { false }, install: { _ in },
            runner: { _, _, _ in ProcessResult(status: 1, output: "", error: "") }), defaults: .standard)
        busyModel.configureForVisualPreview(state: sampleState(lastResult: "ONLINE"), serviceLoaded: true)
        busyModel.identity.firstName = "Editable draft"
        busyModel.enqueueServiceOperationForTesting { }
        for tab in [AppTab.status, .persona, .settings] {
            busyModel.selectTab(tab)
            try render(PopoverRootView(model: busyModel),
                       to: outputDirectory.appendingPathComponent("\(tab.rawValue)-service-busy.png"))
        }

        let slow = SpeedMeasurement(downloadMbps: 0.8, uploadMbps: 0.2, latencyMilliseconds: 620,
            measuredAt: Date(), gatewayMac: "02:00:00:00:00:05", responsivenessRpm: 55)
        for mode in ["slow", "unknown", "measuring", "failed"] {
            model.configureForVisualPreview(state: sampleState(lastResult: "ONLINE"), serviceLoaded: true, activity: activity,
                diagnostics: [DiagnosticAttempt(id: "quality-preview", steps: [
                    DiagnosticStep(attempt: "quality-preview", phase: "probe", title: "Internet access confirmed",
                        detail: "No portal submission was needed. Speed is measured separately.", status: "ok"),
                    DiagnosticStep(attempt: "quality-preview", phase: "quality", title: mode == "slow" ? "Connection quality limited" : "Connection check complete",
                        detail: mode == "slow" ? slow.qualityMetrics : "The latest connection passed its internet check.", status: mode == "slow" ? "warn" : "ok")
                ])], speedMeasurement: mode == "slow" ? slow : nil,
                speedPhase: mode == "measuring" ? .measuring : .idle, speedTestFailed: mode == "failed")
            model.selectTab(.activity)
            try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("activity-quality-\(mode).png"))
        }

        model.configureForVisualPreview(state: sampleState(lastResult: "ONLINE"), serviceLoaded: true,
            activity: activity, speedMeasurement: nil, speedPhase: .measuring)
        model.selectTab(.status)
        try render(
            PopoverRootView(model: model),
            to: outputDirectory.appendingPathComponent("status-brewing.png")
        )

        model.configureForVisualPreview(
            state: sampleState(lastResult: "ONLINE"),
            serviceLoaded: true,
            activity: activity,
            speedMeasurement: speed
        )
        model.selectTab(.status)
        model.presentQuitReceipt()
        try render(
            PopoverRootView(model: model),
            to: outputDirectory.appendingPathComponent("quit-receipt.png")
        )

        try render(
            CafeWiFiIcon(isConnected: true)
                .frame(width: 48, height: 36)
                .background(Color.black),
            to: outputDirectory.appendingPathComponent("menu-online.png"),
            minimumWidth: 48
        )
        try render(
            CafeWiFiIcon(isConnected: false)
                .frame(width: 48, height: 36)
                .background(Color.black),
            to: outputDirectory.appendingPathComponent("menu-offline.png"),
            minimumWidth: 48
        )

        var diagnostics = PortalDiagnostics(startedAt: Date().addingTimeInterval(-8).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, phase: "reasoning",
            title: "Resolving ambiguous form controls (model pass 2)", actions: 1,
            navigations: 2, reasoningRequests: 2)
        diagnostics.events = [PortalDiagnosticEvent(time: diagnostics.startedAt, title: "Captive portal detected"),
            PortalDiagnosticEvent(time: diagnostics.startedAt + 2, title: "Loading the portal in the browser"),
            PortalDiagnosticEvent(time: diagnostics.startedAt + 5, title: "Inspecting page 2 for fields and continue buttons")]
        model.configureForVisualPreview(state: sampleState(lastResult: "CAPTIVE"), serviceLoaded: true,
            activity: activity, activeOperation: .handlingPortal, portalDiagnostics: diagnostics)
        model.selectTab(.activity)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("activity-live-portal.png"))
        model.selectTab(.status)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("status-live-portal.png"))
        diagnostics.failureCode = -1009
        diagnostics.advance(phase: "stopped", title: "Sign-in stopped — needs attention", terminal: true,
            reason: "browser_network_unavailable")
        model.configureForVisualPreview(state: sampleState(lastResult: "CAPTIVE"), serviceLoaded: true,
            activity: activity, portalDiagnostics: diagnostics, portalAttemptNeedsRetry: true)
        model.selectTab(.activity)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("activity-stopped-portal.png"))

        // Rejoining an already-authorised network produces no new portal
        // journey. Its verified connection must replace the old failure card.
        var rejoinedState = sampleState(lastResult: "ONLINE")
        rejoinedState.venue = "Starbucks"
        model.configureForVisualPreview(state: rejoinedState, serviceLoaded: true,
            activity: activity, portalDiagnostics: diagnostics)
        model.selectTab(.activity)
        try render(PopoverRootView(model: model), to: outputDirectory.appendingPathComponent("activity-online-after-failure.png"))

        print(outputDirectory.path)
    }

    private static func render<V: View>(
        _ view: V,
        to url: URL,
        minimumWidth: CGFloat = 406
    ) throws {
        let hostingView = NSHostingView(
            rootView: ZStack {
                CoffeeTheme.surface
                view
            }
                .environment(\.colorScheme, .dark)
                .fixedSize(horizontal: false, vertical: true)
        )
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(minimumWidth, fittingSize.width),
                height: max(1, fittingSize.height)
            )
        )
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw PreviewError.renderFailed
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let data = bitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw PreviewError.renderFailed
        }
        try data.write(to: url, options: .atomic)
    }

    private static func sampleState(lastResult: String) -> AgentState {
        AgentState(
            ssid: "Example Guest 5G",
            venue: "Example Coffee",
            gatewayMac: "02:00:00:00:00:05",
            portalDomain: "wifi.thenook.example",
            dhcpDomain: nil,
            lastResult: lastResult,
            lastCheckTimestamp: Date().timeIntervalSince1970 - 12,
            lastConnectionTimestamp:
                Date().timeIntervalSince1970 - 10_457,
            lastLoginTimestamp: Date().timeIntervalSince1970 - 4_800,
            lastLoginGatewayMac: "02:00:00:00:00:05",
            consecutiveFailures: 0,
            lastReassociationTimestamp: nil
        )
    }

    private static func sampleActivity() -> [ActivityEvent] {
        [
            ActivityEvent(
                id: "4",
                timestamp: "2000-01-01 10:47:03",
                occurredAt: Date(),
                title: "Recovered without radio toggle",
                detail: "Back online in 3.0s",
                kind: .success,
                category: .automaticSignIn,
                gatewayMac: "02:00:00:00:00:05"
            ),
            ActivityEvent(
                id: "3",
                timestamp: "2000-01-01 10:47:00",
                occurredAt: Date().addingTimeInterval(-3),
                title: "Session expired",
                detail: "Portal re-presented after 95 minutes",
                kind: .attention,
                category: .portal,
                gatewayMac: "02:00:00:00:00:05"
            ),
            ActivityEvent(
                id: "2",
                timestamp: "2000-01-01 09:12:03",
                occurredAt: Date().addingTimeInterval(-5_700),
                title: "Connected automatically",
                detail: "Wireless Social portal · persona submitted · 2.8s",
                kind: .success,
                category: .automaticSignIn,
                gatewayMac: "02:00:00:00:00:05"
            ),
            ActivityEvent(
                id: "1",
                timestamp: "2000-01-01 09:12:00",
                occurredAt: Date().addingTimeInterval(-5_703),
                title: "Connected to Example Guest 5G",
                detail: "New venue: Example Coffee",
                kind: .information,
                category: .connection,
                gatewayMac: "02:00:00:00:00:05"
            ),
        ]
    }

    private enum PreviewError: Error {
        case renderFailed
    }
}

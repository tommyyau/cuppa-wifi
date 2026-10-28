import AppKit
import CoreLocation
import CoreWLAN
import Foundation
import CuppaEngine
import SwiftUI

enum SpeedTestPhase: Equatable {
    case idle
    case measuring
    case revealing
}

@MainActor
final class StatusModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var state: AgentState = .unknown
    @Published private(set) var serviceLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var activeOperation: ActiveOperation?
    @Published private(set) var message = ""
    private var renderedDiagnosticAttempt: String?
    @Published private(set) var diagnosticAttempts: [DiagnosticAttempt] = []
    @Published private(set) var activity: [ActivityEvent] = []
    @Published private(set) var portalDiagnostics: PortalDiagnostics?
    @Published private(set) var selectedTab: AppTab = .status
    @Published private(set) var hasUnreadActivity = false
    @Published private(set) var isQuitReceiptPresented = false
    @Published private(set) var isQuitting = false
    @Published private(set) var networkName: String?
    @Published private(set) var speedMeasurement: SpeedMeasurement?
    /// Where a speed test is in its lifecycle. `measuring` = networkQuality is
    /// running and we don't yet know the value (beans pulse); `revealing` = the
    /// value is in and the count-up ramp is playing (beans creep to the result).
    @Published private(set) var speedPhase: SpeedTestPhase = .idle
    @Published private(set) var speedTestMessage = ""
    @Published private(set) var speedTestFailed = false
    /// Wall-clock start of the current measuring phase, so the view can rotate
    /// its status text ("Preparing…" → "Finishing up…") in step with the run.
    @Published private(set) var speedTestStartedAt: Date?
    private var speedTestGatewayMac: String?
    private var speedTestConnectionTimestamp: TimeInterval?
    /// Download value that drives the bean meter's live count-up ramp while a
    /// test runs. Only consulted while testing; committed readings come from
    /// `speedMeasurement`.
    @Published private(set) var displayDownloadMbps: Double = 0

    var isSpeedTesting: Bool { speedPhase != .idle }
    var isTestingCurrentConnection: Bool {
        isSpeedTesting && state.lastResult == "ONLINE"
            && state.gatewayMac == speedTestGatewayMac
            && state.lastConnectionTimestamp == speedTestConnectionTimestamp
    }
    var isMeasuringSpeed: Bool { isTestingCurrentConnection && speedPhase == .measuring }
    @Published private(set) var portalAttemptNeedsRetry = false
    @Published var identity: FakeIdentity = .sarahChen
    @Published var preferences = AgentPreferences(
        interval: .thirtySeconds,
        ignorePersonalHotspots: true,
        resetWiFiAfterFailures: false
    )
    private var savedIdentity: FakeIdentity = .sarahChen
    /// Draft edits belong to the Persona editor until Save Persona succeeds.
    var portalIdentity: FakeIdentity { savedIdentity }
    private var savedPreferences = AgentPreferences(
        interval: .thirtySeconds,
        ignorePersonalHotspots: true,
        resetWiFiAfterFailures: false
    )
    var automaticSpeedTestsEnabled: Bool { savedPreferences.automaticSpeedTests }
    private let locationManager = CLLocationManager()
    private var pendingServiceOperations = 0
    private var serviceOperation: ActiveOperation?
    private var checkingConnection = false { didSet { updateOperationState() } }
    private var verifyingAccess = false { didSet { updateOperationState() } }
    private var portalOperation: ActiveOperation? { didSet { updateOperationState() } }
    private var previewOperation: ActiveOperation?
    private var deferredWebViewHandoff = false
    private var deferredForcedWebViewHandoff = false

    @Published private var pendingMonitoringEnabled: Bool?

    var monitoringEnabled: Bool { pendingMonitoringEnabled ?? serviceLoaded }
    private var serviceOperationTask: Task<Void, Never>?
    private var serviceRefreshTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var activityFileTracker = FileChangeTracker()
    private var messageClearTask: Task<Void, Never>?
    private var webViewAutopilot: WebViewAutopilotController?
    private var assistedPortal: WebViewAutopilotController?
    private var assistedFingerprint: String?
    @Published private(set) var canFinishPortal = false
    private var lastWebViewAttempt: [String: Date] = [:]
    private var portalRetryAttemptedAt: Date?
    private var newestSeenActivityID: String?
    private var hasLoadedInitialActivity = false
    private var suppressExternalRefresh = false
    private var networkNameRefreshDelay = NetworkNameRefreshDelay()
    private var captivePortalDismissalGate = CaptivePortalDismissalGate()

    private let serviceOperations: EngineServiceOperations
    private let preferenceDefaults: UserDefaults

    override convenience init() {
        self.init(serviceOperations: EngineServiceOperations(), defaults: .standard)
    }

    init(serviceOperations: EngineServiceOperations, defaults: UserDefaults) {
        self.serviceOperations = serviceOperations
        self.preferenceDefaults = defaults
        super.init()
        locationManager.delegate = self
    }

    private var monitoringPreference: Bool {
        get { preferenceDefaults.object(forKey: "monitoringEnabled") == nil ? true : preferenceDefaults.bool(forKey: "monitoringEnabled") }
        set { preferenceDefaults.set(newValue, forKey: "monitoringEnabled") }
    }

    func bootstrap() {
        guard !isBusy, !isQuitting else { return }
        let needsIdentityMigration = !FileManager.default.fileExists(atPath: SystemPaths.sharedIdentityFile().path)
        identity = IdentityStore.load()
        savedIdentity = identity
        preferences = AgentPreferencesStore.load(identity: identity, defaults: preferenceDefaults)
        savedPreferences = preferences
        enqueueServiceOperation(named: .starting) { [self] in
            refresh()
            do {
                let changed = try await serviceOperations.syncBundledEngine()
                if needsIdentityMigration {
                    let migratedIdentity = IdentityStore.load()
                    if identity == savedIdentity { identity = migratedIdentity }
                    savedIdentity = migratedIdentity
                    let migratedPreferences = AgentPreferencesStore.load(identity: migratedIdentity, defaults: preferenceDefaults)
                    if preferences == savedPreferences { preferences = migratedPreferences }
                    savedPreferences = migratedPreferences
                }
                serviceLoaded = await serviceOperations.queryServiceLoaded()
                refresh()
                if monitoringPreference {
                    if changed || !serviceLoaded {
                        try await serviceOperations.installService(
                            interval: savedPreferences.interval
                        )
                        showMessage("Automatic monitoring ready")
                    }
                } else if serviceLoaded {
                    let result = await serviceOperations.unloadService()
                    if result.status != 0, await serviceOperations.queryServiceLoaded() {
                        showMessage("Could not turn off monitoring: \(result.error)")
                    }
                }
            } catch {
                showMessage(error.localizedDescription)
            }
            refresh()
            refreshActivity(markAsSeen: true)
            startRefreshLoop()
        }
    }

    func refresh(forceWebView: Bool = false) {
        portalDiagnostics = PortalDiagnostics.load(from: SystemPaths.portalProgress)
        let previousState = state
        let previousGateway = previousState.gatewayMac
        let refreshedState = AgentStateLoader.load(
            from: SystemPaths.stateFile
        )
        let shouldDismissCaptivePortal =
            captivePortalDismissalGate.shouldDismiss(
                previous: previousState,
                refreshed: refreshedState
            )
        if previousGateway != nil,
           refreshedState.gatewayMac != previousGateway
        {
            networkName = nil
        }
        if refreshedState.gatewayMac != previousGateway {
            networkNameRefreshDelay.noteGatewayChange(
                to: refreshedState.gatewayMac
            )
        }
        if (previousGateway != refreshedState.gatewayMac) || previousState.ssid != refreshedState.ssid || previousState.dhcpDomain != refreshedState.dhcpDomain || refreshedState.lastResult == "ONLINE" || refreshedState.lastResult == "NO_NETWORK" {
            assistedPortal?.discard()
            assistedPortal = nil
            assistedFingerprint = nil
            canFinishPortal = false
            if previousGateway != refreshedState.gatewayMac || previousState.ssid != refreshedState.ssid || previousState.dhcpDomain != refreshedState.dhcpDomain || refreshedState.lastResult == "ONLINE" || refreshedState.lastResult == "NO_NETWORK" {
                webViewAutopilot?.discard()
                webViewAutopilot = nil
                portalOperation = nil
            }
        }
        state = refreshedState
        persistEngineVenueName()
        if refreshedState.lastResult != "CAPTIVE" {
            portalAttemptNeedsRetry = false
            portalRetryAttemptedAt = nil
        }
        if shouldDismissCaptivePortal {
            dismissCaptiveNetworkAssistant()
        }
        if previousGateway != refreshedState.gatewayMac
            || previousState.lastConnectionTimestamp != refreshedState.lastConnectionTimestamp {
            speedTestMessage = ""
            speedTestFailed = false
        }
        if previousGateway != refreshedState.gatewayMac
            || speedMeasurement == nil
        {
            speedMeasurement = SpeedMeasurementStore.load(
                for: refreshedState.gatewayMac
            )
            displayDownloadMbps = speedMeasurement?.downloadMbps ?? 0
        }
        if !suppressExternalRefresh && serviceRefreshTask == nil && pendingServiceOperations == 0 && !isQuitting {
            serviceRefreshTask = Task {
                let loaded = await serviceOperations.queryServiceLoaded()
                if !Task.isCancelled {
                    serviceLoaded = loaded
                    serviceRefreshTask = nil
                }
            }
        }
        refreshNetworkName()
        considerWebViewHandoff(force: forceWebView)
        scheduleAutomaticSpeedTestIfNeeded()
        refreshActivity()
    }

    func checkNow() {
        guard !checkNowIsDisabled, !isQuitting else { return }
        portalAttemptNeedsRetry = false
        checkingConnection = true
        let previousLoginTimestamp = state.lastLoginTimestamp
        Task {
            let result = await EngineCLI.execute(arguments: ["--once"], resources: SystemPaths.resources)
            checkingConnection = false
            refresh(forceWebView: true)
            guard result.status == 0 else {
                showMessage("Check failed: \(result.error)")
                return
            }
            switch state.lastResult {
            case "ONLINE":
                if state.lastLoginTimestamp != nil,
                   state.lastLoginTimestamp != previousLoginTimestamp
                {
                    showMessage(
                        "Portal completed automatically—you’re online"
                    )
                } else {
                    showMessage("Already online. No portal to handle.")
                }
            case "CAPTIVE":
                if webViewAutopilot == nil {
                    showMessage(
                        "Portal detected, but automatic sign-in needs attention"
                    )
                }
            case "UNSUPPORTED":
                showMessage(
                    portalPageUnavailable ? ActivityLog.attentionDetail(for: "portal_page_unavailable")
                        : "This portal needs verification or venue credentials"
                )
            case "NO_NETWORK":
                showMessage(
                    state.networkDiagnostic?.title ?? "Wi-Fi is not ready yet—automatic monitoring will retry"
                )
            case "IGNORED":
                showMessage("This network is excluded from automatic sign-in")
            default:
                showMessage(
                    "Connection check finished without a clear result"
                )
            }
        }
    }

    func restartMonitoring() {
        guard !isBusy, !isQuitting else { return }
        pendingMonitoringEnabled = true
        enqueueServiceOperation { [self] in
            do {
                _ = try await serviceOperations.syncBundledEngine()
                try await serviceOperations.installService(
                    interval: savedPreferences.interval
                )
                monitoringPreference = true
                showMessage("Automatic monitoring restarted")
            } catch {
                showMessage(error.localizedDescription)
            }
            refresh()
        }
    }

    func pauseMonitoring() {
        guard !isBusy, !isQuitting else { return }
        pendingMonitoringEnabled = false
        enqueueServiceOperation { [self] in
            webViewAutopilot?.discard()
            webViewAutopilot = nil
            assistedPortal?.discard()
            assistedPortal = nil
            canFinishPortal = false
            portalOperation = nil
            let result = await serviceOperations.unloadService()
            let stillLoaded = await serviceOperations.queryServiceLoaded()
            if !stillLoaded { monitoringPreference = false }
            showMessage(
                !stillLoaded
                    ? "Automatic monitoring turned off"
                    : "Could not turn off monitoring: \(result.error)"
            )
            refresh()
        }
    }

    @discardableResult
    func stopMonitoringForQuit() async -> Bool {
        await serviceOperationTask?.value
        serviceRefreshTask?.cancel()
        serviceRefreshTask = nil
        serviceLoaded = await serviceOperations.queryServiceLoaded()
        let resumeMonitoringOnNextLaunch =
            monitoringPreference
        refreshTask?.cancel()
        refreshTask = nil
        webViewAutopilot?.discard()
        webViewAutopilot = nil
        assistedPortal?.discard()
        assistedPortal = nil
        canFinishPortal = false
        portalOperation = nil
        if serviceLoaded {
            let result = await serviceOperations.unloadService()
            let stillLoaded = await serviceOperations.queryServiceLoaded()
            guard !stillLoaded else {
                showMessage(
                    "Could not stop automatic monitoring: \(result.error)"
                )
                startRefreshLoop()
                return false
            }
        }
        monitoringPreference =
            resumeMonitoringOnNextLaunch
        serviceLoaded = false
        return true
    }

    func setMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            restartMonitoring()
        } else {
            pauseMonitoring()
        }
    }

    func selectTab(_ tab: AppTab) {
        selectedTab = tab
        clearMessage()
        if tab == .activity {
            if suppressExternalRefresh {
                newestSeenActivityID = activity.first?.id
                hasUnreadActivity = false
            } else {
                refreshActivity(markAsSeen: true)
            }
        }
    }

    func presentQuitReceipt() {
        if !suppressExternalRefresh {
            refreshActivity()
        }
        isQuitReceiptPresented = true
    }

    func popoverDidAppear() {
        if !suppressExternalRefresh {
            refresh()
        }
    }

    func activityDidAppear() {
        if !suppressExternalRefresh {
            refreshActivity(markAsSeen: true)
        }
    }

    func dismissQuitReceipt() {
        guard !isQuitting else { return }
        isQuitReceiptPresented = false
    }

    func confirmQuit() {
        guard !isQuitting else { return }
        isQuitting = true
        Task {
            await Task.yield()
            if await stopMonitoringForQuit() {
                NSApplication.shared.terminate(nil)
            } else {
                isQuitting = false
                isQuitReceiptPresented = false
            }
        }
    }

    func copyPersonaEmail() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(identity.email, forType: .string)
        showMessage("Email address copied")
    }

    func refreshActivity(markAsSeen: Bool = false) {
        if activityFileTracker.hasChanges(at: [SystemPaths.logFile]) {
            let text = (try? String(contentsOf: SystemPaths.logFile, encoding: .utf8)) ?? ""
            diagnosticAttempts = DiagnosticTrace.parse(text)
            let refreshed = Array(ActivityLog.parse(text).suffix(30).reversed()).map { event in
                guard event.title == "Connected successfully",
                      event.detail == "Internet is available on network",
                      let gatewayMac = event.gatewayMac,
                      // A shared/virtual MAC is not a venue identity: a legacy
                      // cached label for it could relabel activity from an
                      // unrelated venue on the same MAC.
                      !GatewayMAC.isShared(gatewayMac),
                      let venue = UserDefaults.standard.string(
                          forKey: NetworkNameCache.key(for: gatewayMac)
                      )
                else {
                    return event
                }
                return ActivityEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    occurredAt: event.occurredAt,
                    title: event.title,
                    detail: "Internet is available on \(venue)",
                    kind: event.kind,
                    category: event.category,
                    gatewayMac: event.gatewayMac
                )
            }
            activity = refreshed
        }
        let refreshed = activity

        if !hasLoadedInitialActivity {
            hasLoadedInitialActivity = true
            newestSeenActivityID = refreshed.first?.id
            hasUnreadActivity = false
            return
        }

        if markAsSeen || selectedTab == .activity {
            newestSeenActivityID = refreshed.first?.id
            hasUnreadActivity = false
        } else if let newest = refreshed.first?.id,
                  newest != newestSeenActivityID
        {
            hasUnreadActivity = true
        }
    }

    var statusCupState: StatusCupState {
        switch state.lastResult {
        case "ONLINE":
            .online
        case "CAPTIVE":
            state.consecutiveFailures > 0 ? .offline : .signingIn
        default:
            .offline
        }
    }

    // After this many consecutive failures we stop implying "just wait a bit
    // longer" and tell the user to sign in themselves. The engine's fast-retry
    // increments this once per in-process attempt (~4-5 within one 30s cycle),
    // so 4 means "it has genuinely tried and isn't getting in". A fail-closed
    // portal (UNSUPPORTED: OTP/CAPTCHA/voucher/real detail) needs manual
    // sign-in immediately — no amount of waiting will help.
    /// True when automatic sign-in has given up and the user must complete the
    /// portal themselves — so the UI can say so plainly instead of leaving them
    /// watching a countdown. Clears automatically once they're online. See
    /// ManualSignInPolicy for the give-up rule.
    var needsManualLogin: Bool {
        !portalPageUnavailable && ManualSignInPolicy.required(
            lastResult: state.lastResult,
            consecutiveFailures: state.consecutiveFailures,
            hasActiveOperation: activeOperation != nil
        )
    }

    var portalPageUnavailable: Bool {
        state.lastResult == "UNSUPPORTED" && portalDiagnostics?.reason == "portal_page_unavailable"
    }

    var statusTitle: String {
        if portalPageUnavailable { return activeOperation?.title ?? "Portal unavailable" }
        if needsManualLogin {
            return "Manual sign-in needed"
        }
        if portalAttemptNeedsRetry {
            return "Sign-in needs retry"
        }
        return activeOperation?.title ?? state.statusTitle
    }

    var statusSubtitle: String {
        let venue = friendlyVenueDisplayName
        switch activeOperation {
        case .starting:
            return "Preparing automatic sign-in…"
        case .checkingConnection:
            return "Checking \(venue) and looking for a portal…"
        case .handlingPortal:
            return "Filling and submitting the portal at \(venue)…"
        case .verifyingAccess:
            return "Portal submitted at \(venue); verifying access…"
        case .updatingMonitoring:
            return "Applying the monitoring change…"
        case nil:
            break
        }
        if portalPageUnavailable {
            return "\(venue) · the venue needs to check its sign-in page. Try another network."
        }
        if needsManualLogin {
            return canFinishPortal
                ? "\(venue) · Use Finish sign-in to complete the missing step."
                : "\(venue) · Open the Wi-Fi login page to finish signing in."
        }
        if portalAttemptNeedsRetry {
            return "The last portal attempt stopped at \(venue)"
        }
        switch state.lastResult {
        case "ONLINE":
            guard state.lastLoginTimestamp != nil, state.lastLoginGatewayMac == state.gatewayMac else {
                return "Internet access confirmed · \(venue)"
            }
            let name = "\(savedIdentity.firstName) \(savedIdentity.lastName)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "Signed in as \(name) · \(venue)"
        case "CAPTIVE":
            return state.consecutiveFailures > 0
                ? "Couldn’t complete the portal at \(venue)"
                : "Filling portal form at \(venue)…"
        case "UNSUPPORTED":
            return "\(venue) · verification required"
        case "IGNORED":
            return "\(venue) · automatic sign-in skipped"
        case "NO_NETWORK":
            return state.networkDiagnostic?.title ?? "\(venue) · no internet access"
        default:
            return "\(venue) · waiting for the first check"
        }
    }

    var friendlyVenueDisplayName: String {
        for candidate in [
            // The Location-revealed Wi-Fi name wins when we have it (that's
            // what the "Show Wi-Fi name" button unlocks); otherwise fall back
            // to the handler venue, then the portal/DHCP identifiers.
            networkName,
            state.venue,
            // Known venue for this MAC from a prior visit — beats showing the
            // generic portal domain (or nothing) when we return to an already
            // authorised network and the engine skips portal identification.
            cachedEngineVenueName,
            state.ssid,
            state.portalDomain,
            state.dhcpDomain,
        ] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty,
               trimmed.lowercased() != "unknown"
            {
                return trimmed
            }
        }
        return "Current Wi-Fi"
    }

    var activityVenueDisplayName: String {
        // The activity log already retains names from earlier connections.
        // Reuse that saved label only for a stable, non-shared gateway when
        // the live SSID is unavailable; this performs no new Location query.
        if networkName == nil, state.ssid == nil,
           let gateway = state.gatewayMac, !GatewayMAC.isShared(gateway),
           let saved = UserDefaults.standard.string(forKey: NetworkNameCache.key(for: gateway))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
           !saved.isEmpty {
            return saved
        }
        return friendlyVenueDisplayName
    }

    func timeConnected(at date: Date = Date()) -> String {
        guard state.lastResult == "ONLINE",
              let timestamp = state.lastConnectionTimestamp
        else {
            return "--"
        }
        return ConnectionDurationFormatter.string(
            from: Date(timeIntervalSince1970: timestamp),
            to: date
        )
    }

    var receiptVenueTitle: String {
        friendlyVenueDisplayName.uppercased()
    }

    #if DEBUG
    func configureForVisualPreview(
        state: AgentState,
        serviceLoaded: Bool,
        activity: [ActivityEvent] = [],
        diagnostics: [DiagnosticAttempt] = [],
        speedMeasurement: SpeedMeasurement? = nil,
        activeOperation: ActiveOperation? = nil,
        portalDiagnostics: PortalDiagnostics? = nil,
        portalAttemptNeedsRetry: Bool = false,
        canFinishPortal: Bool = false,
        speedPhase: SpeedTestPhase = .idle,
        speedTestFailed: Bool = false,
        speedTestState: AgentState? = nil
    ) {
        self.state = state
        self.serviceLoaded = serviceLoaded
        self.activity = activity
        self.diagnosticAttempts = diagnostics
        self.speedMeasurement = speedMeasurement
        self.displayDownloadMbps = speedMeasurement?.downloadMbps ?? 0
        self.speedTestGatewayMac = (speedTestState ?? state).gatewayMac
        self.speedTestConnectionTimestamp = (speedTestState ?? state).lastConnectionTimestamp
        self.speedPhase = speedPhase
        self.speedTestFailed = speedTestFailed
        self.speedTestStartedAt = speedPhase == .measuring ? Date() : nil
        self.previewOperation = activeOperation
        self.portalDiagnostics = portalDiagnostics
        self.portalAttemptNeedsRetry = portalAttemptNeedsRetry
        self.canFinishPortal = canFinishPortal
        self.isQuitReceiptPresented = false
        updateOperationState()
        suppressExternalRefresh = true
        hasLoadedInitialActivity = true
        newestSeenActivityID = activity.first?.id
        hasUnreadActivity = false
    }
    #endif

    func revealRawLog() {
        guard FileManager.default.fileExists(atPath: SystemPaths.logFile.path)
        else {
            showMessage("No raw log has been created yet")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([SystemPaths.logFile])
    }

    func copySupportSummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(supportSummary, forType: .string)
        showMessage("Support summary copied — includes network names")
    }

    var supportSummary: String {
        let portalDetail = state.lastResult == "NO_NETWORK" && state.networkDiagnostic != nil
            ? "\(state.networkDiagnostic!.title). \(state.networkDiagnostic!.detail) Checks: \(state.networkDiagnostic!.checks); consecutive checks=\(state.networkDiagnostic!.consecutiveChecks)"
            : state.lastResult == "ONLINE"
            ? "Internet access confirmed on \(activityVenueDisplayName)"
            : portalDiagnostics.map { record in
            "\(record.title); actions=\(record.actions), pages=\(record.navigations), model passes=\(record.reasoningRequests), reason=\(record.reason ?? "none"), error=\(record.failureCode ?? 0)"
        } ?? "No portal attempt recorded"
        let recent = activity.prefix(10).map {
            "\($0.timestamp) — \($0.title): \($0.detail)"
        }.joined(separator: "\n")
        return """
        Cuppa Wi-Fi support summary
        Status: \(statusTitle)
        Background monitor: \(serviceLoaded ? "running" : "paused")
        Apple local model: \(LocalPortalReasoner.makeAvailable() == nil ? "unavailable (rules and manual assistance remain available)" : "available; called only when a portal needs interpretation")
        Venue: \(venueDisplayName)
        Last sign-in: \(lastLoginText)
        Consecutive failures: \(state.consecutiveFailures)
        Portal diagnostic: \(portalDetail)

        Recent important activity:
        \(recent.isEmpty ? "None" : recent)
        """
    }

    var venueDisplayName: String {
        for candidate in [
            networkName,
            state.ssid,
            state.venue,
            cachedEngineVenueName,
            state.portalDomain,
            state.dhcpDomain,
        ] {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !trimmed.isEmpty,
               trimmed.lowercased() != "unknown"
            {
                return trimmed
            }
        }
        return "Current Wi-Fi"
    }

    var needsNetworkNameAccess: Bool {
        // The button is the deliberate, one-time choice to grant Location so
        // macOS reveals the real Wi-Fi name. Offer it whenever we're on a
        // network but Location isn't authorised yet — independent of any name
        // cached from a previous grant (which is why it had gone missing).
        guard state.gatewayMac != nil else { return false }
        return !isLocationAuthorized
    }

    private var isLocationAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorized, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    func requestNetworkNameAccess() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            showMessage(
                "Allow Location once so macOS can reveal the Wi-Fi name"
            )
            locationManager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            refreshNetworkName()
        case .denied, .restricted:
            if let settings = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
            ) {
                NSWorkspace.shared.open(settings)
            }
            showMessage(
                "Enable Location for Cuppa Wi-Fi to show network names"
            )
        @unknown default:
            showMessage("macOS did not provide the Wi-Fi name")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(
        _ manager: CLLocationManager
    ) {
        Task { @MainActor in
            refreshNetworkName()
        }
    }

    // Persist the engine-identified venue name (e.g. "Nando's", derived from
    // the captive portal — no Location needed) under a stable, non-shared
    // gateway MAC. On a later return to the same venue whose session is still
    // authorised, macOS goes straight online and the engine never re-runs
    // portal identification, so state.venue is empty; this cache lets us still
    // show the real venue name instead of a bare "Current Wi-Fi". Shared
    // virtual-router MACs are excluded (they collide across venues — see
    // GatewayMAC.isShared and the venue.<mac> SSID cache above).
    private func persistEngineVenueName() {
        guard let key = state.gatewayMac,
              !GatewayMAC.isShared(key),
              let venue = state.venue?.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !venue.isEmpty,
              venue.lowercased() != "unknown"
        else { return }
        UserDefaults.standard.set(venue, forKey: "venueName.\(key)")
    }

    // The engine venue name last seen on the current (non-shared) gateway MAC.
    private var cachedEngineVenueName: String? {
        guard let key = state.gatewayMac, !GatewayMAC.isShared(key) else {
            return nil
        }
        return UserDefaults.standard.string(forKey: "venueName.\(key)")
    }

    private func refreshNetworkName() {
        networkName = nil
        // Only surface a Wi-Fi name once Location is granted (via the button).
        // Without it we intentionally show the portal name and keep offering
        // the button, rather than silently using a cached name.
        guard isLocationAuthorized else { return }
        if networkNameRefreshDelay.shouldDefer(
            gateway: state.gatewayMac
        ) {
            return
        }
        // A live SSID from CoreWLAN (Location-gated) is always authoritative.
        // Cache it only under a gateway MAC that actually identifies one
        // venue: shared virtual-router MACs (HSRP/GLBP/VRRP) are reused across
        // unrelated venues, so caching there would relabel the next venue on
        // the same MAC (a Nando's name shown at a Picturehouse). See
        // GatewayMAC.isShared.
        if let ssid = CWWiFiClient.shared().interface()?.ssid(),
           !ssid.isEmpty
        {
            networkName = ssid
            if let key = state.gatewayMac, NetworkNameCache.canStore(ssid, state: state) {
                UserDefaults.standard.set(ssid, forKey: NetworkNameCache.key(for: key))
            }
            return
        }
        // No live SSID (Location not granted): fall back to the MAC-keyed
        // cache only when that MAC is a stable venue identity. On a shared
        // MAC we intentionally show nothing here and let the caller fall
        // through to the engine's venue/portal fields rather than a name
        // cached from a different venue.
        if let key = state.gatewayMac,
           !GatewayMAC.isShared(key),
           let saved = UserDefaults.standard.string(forKey: NetworkNameCache.key(for: key))
        {
            networkName = saved
        }
    }

    private func dismissCaptiveNetworkAssistant() {
        let bundleIdentifier = "com.apple.CaptiveNetworkAssistant"
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) {
            _ = application.terminate()
        }
    }

    func revealDiagnosticCaptures() {
        try? FileManager.default.createDirectory(
            at: SystemPaths.installedCaptures,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(SystemPaths.installedCaptures)
    }

    var persistentChangesDisabled: Bool { pendingServiceOperations > 0 || isQuitting }

    func saveIdentity() {
        guard !persistentChangesDisabled else { return }
        do {
            var persona = identity
            persona.ignoreHotspots = savedPreferences.ignorePersonalHotspots
            persona.reassociationEnabled =
                savedPreferences.resetWiFiAfterFailures
            try IdentityStore.save(persona)
            identity = persona
            savedIdentity = persona
            showMessage("Persona saved")
        } catch {
            showMessage(
                "Could not save identity: \(error.localizedDescription)"
            )
        }
    }

    func generateIdentity() {
        var persona = FakeIdentity.generated()
        persona.ignoreHotspots = savedPreferences.ignorePersonalHotspots
        persona.reassociationEnabled =
            savedPreferences.resetWiFiAfterFailures
        identity = persona
        showMessage("New persona generated—save or discard the changes")
    }

    func discardIdentityChanges() {
        identity = savedIdentity
        showMessage("Unsaved persona changes discarded")
    }

    var identityHasUnsavedChanges: Bool {
        identity != savedIdentity
    }

    func savePreferences() {
        guard !isBusy, !isQuitting else { return }
        let requestedPreferences = preferences
        enqueueServiceOperation { [self] in
            let previousIdentity = savedIdentity
            let needsServiceUpdate = serviceLoaded && requestedPreferences.interval != savedPreferences.interval
            var wroteIdentity = false
            do {
                if needsServiceUpdate { _ = try await serviceOperations.syncBundledEngine() }
                var persistedIdentity = savedIdentity
                persistedIdentity.ignoreHotspots =
                    requestedPreferences.ignorePersonalHotspots
                persistedIdentity.reassociationEnabled =
                    requestedPreferences.resetWiFiAfterFailures
                try IdentityStore.save(persistedIdentity)
                wroteIdentity = true
                if needsServiceUpdate {
                    try await serviceOperations.installService(interval: requestedPreferences.interval)
                }
                AgentPreferencesStore.save(requestedPreferences, defaults: preferenceDefaults)
                savedIdentity = persistedIdentity
                identity.ignoreHotspots = requestedPreferences.ignorePersonalHotspots
                identity.reassociationEnabled =
                    requestedPreferences.resetWiFiAfterFailures
                savedPreferences = requestedPreferences
                showMessage("Advanced settings applied")
            } catch {
                // The installer restores its previous plist and monitoring state.
                // Restore Persona flags independently; do not run another install
                // after a failed rollback and hide the original service error.
                if wroteIdentity {
                    try? IdentityStore.save(previousIdentity)
                }
                showMessage(
                    "Could not apply advanced settings: \(error.localizedDescription)"
                )
            }
            refresh()
        }
    }

    func discardPreferenceChanges() {
        guard pendingServiceOperations == 0 else { return }
        preferences = savedPreferences
        showMessage("Unsaved settings discarded")
    }

    var preferencesHaveUnsavedChanges: Bool {
        preferences != savedPreferences
    }

    func setAutomaticSpeedTests(_ enabled: Bool) {
        guard !persistentChangesDisabled else { return }
        // Save this switch alone: leave Persona and advanced-setting drafts intact.
        savedPreferences.automaticSpeedTests = enabled
        preferences.automaticSpeedTests = enabled
        AgentPreferencesStore.save(savedPreferences, defaults: preferenceDefaults)
        showMessage(enabled ? "Automatic speed tests on" : "Automatic speed tests off")
    }

    func setIgnorePersonalHotspots(_ enabled: Bool) {
        guard !persistentChangesDisabled else { return }
        do {
            // This switch applies immediately, without committing drafts of
            // the interval, speed-test setting or Persona.
            var persistedIdentity = savedIdentity
            persistedIdentity.ignoreHotspots = enabled
            try IdentityStore.save(persistedIdentity)
            savedIdentity = persistedIdentity
            identity.ignoreHotspots = enabled
            savedPreferences.ignorePersonalHotspots = enabled
            preferences.ignorePersonalHotspots = enabled
            showMessage("Hotspot preference saved")
        } catch {
            showMessage("Could not save hotspot preference: \(error.localizedDescription)")
        }
    }

    var monitoringSummary: String {
        serviceLoaded
            ? "Checks every \(savedPreferences.interval.label)"
            : "Automatic monitoring is off"
    }

    private func showMessage(_ text: String) {
        messageClearTask?.cancel()
        message = text
        guard !text.isEmpty else { return }
        messageClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(4_500))
            guard !Task.isCancelled, self?.message == text else { return }
            self?.message = ""
        }
    }

    private func clearMessage() {
        messageClearTask?.cancel()
        messageClearTask = nil
        message = ""
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var files = FileChangeTracker()
            var lastFullRefresh = Date.distantPast
            while !Task.isCancelled {
                let active = self?.activeOperation != nil || self?.state.lastResult == "CAPTIVE"
                try? await Task.sleep(for: .seconds(active ? 1 : 5))
                guard !Task.isCancelled else { return }
                if files.hasChanges(at: [SystemPaths.stateFile, SystemPaths.webViewHandoff])
                    || Date().timeIntervalSince(lastFullRefresh) >= 60 {
                    self?.refresh()
                    lastFullRefresh = Date()
                } else {
                    let record = PortalDiagnostics.load(from: SystemPaths.portalProgress)
                    if self?.portalDiagnostics != record { self?.portalDiagnostics = record }
                }
                self?.refreshActivity()
            }
        }
    }

    func finishPortalManually() {
        guard canFinishPortal, !isBusy, !isQuitting, webViewAutopilot == nil,
              let controller = assistedPortal, let fingerprint = assistedFingerprint,
              state.lastResult == "CAPTIVE" || state.lastResult == "UNSUPPORTED",
              let lock = SharedEngineLock.acquire(at: SystemPaths.engineLock) else { return }
        lastWebViewAttempt[fingerprint] = Date()
        webViewAutopilot = controller
        canFinishPortal = false
        portalOperation = .handlingPortal
        controller.showAssistedSignIn(lock: lock)
    }

    private func considerWebViewHandoff(force: Bool) {
        guard !isQuitting else { return }
        guard pendingServiceOperations == 0, !checkingConnection, !verifyingAccess else {
            deferredWebViewHandoff = true
            deferredForcedWebViewHandoff = deferredForcedWebViewHandoff || force
            return
        }
        let force = force || deferredForcedWebViewHandoff
        deferredWebViewHandoff = false
        deferredForcedWebViewHandoff = false
        guard (force || serviceLoaded),
              webViewAutopilot == nil,
              let record = WebViewHandoffRecord.load(
                  from: SystemPaths.webViewHandoff
              ),
              state.lastResult == "CAPTIVE" || (state.lastResult == "UNSUPPORTED" && record.manualOnly == true),
              record.isFresh(),
              record.matches(state),
              let portalURL = record.validatedPortalURL,
              let scriptURL = Bundle.main.url(
                  forResource: "autofill",
                  withExtension: "js"
              ),
              let correctionLadderURL = Bundle.main.url(
                  forResource: "correction-ladder",
                  withExtension: "json"
              )
        else {
            return
        }

        let fingerprint = record.venueFingerprint
            ?? state.portalDomain
            ?? state.gatewayMac
            ?? portalURL.host
            ?? portalURL.absoluteString
        if !force,
           let lastAttempt = lastWebViewAttempt[fingerprint],
           !PortalRetrySchedule(
               interval: savedPreferences.interval
           ).isReady(after: lastAttempt)
        {
            return
        }
        guard let engineLock = SharedEngineLock.acquire(
            at: SystemPaths.engineLock
        ) else {
            return
        }
        guard let controller = WebViewAutopilotController(
            portalURL: portalURL,
            identity: portalIdentity,
            scriptURL: scriptURL,
            correctionLadderURL: correctionLadderURL,
            engineLock: engineLock,
            handoff: record,
            diagnosticsDirectory: SystemPaths.sharedDataDirectory().appendingPathComponent("rendered-journeys", isDirectory: true),
            credentials: PortalCredentials.load(for: portalURL),
            accountScope: GatewayMAC.octets(state.gatewayMac) != nil && !GatewayMAC.isShared(state.gatewayMac)
                ? state.gatewayMac?.lowercased() : nil,
            progress: { [weak self] record in
                self?.portalDiagnostics = record
                record.save(to: SystemPaths.portalProgress)
            },
            networkSSID: state.ssid,
            completion: { [weak self] outcome in
                guard let self, let completed = self.webViewAutopilot else { return }
                self.assistedPortal = completed
                self.assistedFingerprint = fingerprint
                self.canFinishPortal = true
                self.webViewAutopilot = nil
                self.portalOperation = nil
                self.handleWebViewOutcome(outcome, fingerprint: fingerprint, reportURL: completed.diagnosticsURL, assisted: completed.assisted)
            }
        ) else {
            showMessage("Could not prepare the rendered portal helper")
            return
        }

        assistedPortal?.discard()
        assistedPortal = nil
        canFinishPortal = false
        lastWebViewAttempt[fingerprint] = Date()
        webViewAutopilot = controller
        portalAttemptNeedsRetry = false
        portalRetryAttemptedAt = nil
        portalOperation = .handlingPortal
        showMessage("Rendered portal detected—signing in automatically…")
        renderedDiagnosticAttempt = controller.diagnosticAttempt
        controller.start()
    }

    private func handleWebViewOutcome(
        _ outcome: WebViewAutopilotController.Outcome,
        fingerprint: String,
        reportURL: URL?,
        assisted: Bool
    ) {
        switch outcome {
        case .submitted:
            persistWebViewOutcome(outcome, fingerprint: fingerprint, reportURL: reportURL, assisted: assisted)
        case .unsupported:
            persistWebViewOutcome(outcome, fingerprint: fingerprint, reportURL: reportURL, assisted: assisted)
        case let .failed(detail):
            portalAttemptNeedsRetry = true
            portalRetryAttemptedAt =
                lastWebViewAttempt[fingerprint] ?? Date()
            showMessage(detail)
        }
    }

    private func persistWebViewOutcome(
        _ outcome: WebViewAutopilotController.Outcome,
        fingerprint: String,
        reportURL: URL?,
        assisted: Bool
    ) {
        var arguments: [String]
        switch outcome {
        case let .submitted(venue):
            var submittedArguments = [
                "--webview-complete",
                "--webview-fingerprint",
                fingerprint,
            ]
            if let venue, !venue.isEmpty {
                submittedArguments += ["--webview-venue", venue]
            }
            submittedArguments.append("--verbose")
            arguments = submittedArguments
            showMessage("Portal submitted—verifying internet access…")
        case let .unsupported(reason):
            arguments = [
                "--webview-unsupported",
                reason,
                "--webview-fingerprint",
                fingerprint,
                "--verbose",
            ]
        case .failed:
            return
        }
        if let reportURL { arguments += ["--webview-report", reportURL.path] }
        if assisted { arguments.append("--webview-assisted") }
        let commandArguments = arguments
        verifyingAccess = true
        portalAttemptNeedsRetry = false
        let diagnosticAttempt = renderedDiagnosticAttempt
        let completedPortal = assistedPortal
        Task {
            let result = await EngineCLI.execute(arguments: commandArguments, resources: SystemPaths.resources)
            verifyingAccess = false
            refresh()
            switch outcome {
            case .submitted:
                if let diagnosticAttempt {
                    let online = result.status == 0 && state.lastResult == "ONLINE"
                    DiagnosticTrace.append(DiagnosticStep(attempt: diagnosticAttempt, phase: "probe", title: online ? "Probe: ONLINE" : "Access verification failed", detail: online ? "Internet access verified" : "Independent probe did not confirm internet access (exit \(result.status))", status: online ? "ok" : "fail"), to: SystemPaths.logFile)
                    refreshActivity()
                }
                if result.status == 0, state.lastResult == "ONLINE" {
                    completedPortal?.rememberVerifiedAccount()
                    if var diagnostics = portalDiagnostics {
                        diagnostics.advance(phase: "connected", title: "Internet access confirmed", terminal: true)
                        diagnostics.save(to: SystemPaths.portalProgress)
                        portalDiagnostics = diagnostics
                    }
                    showMessage(
                        assisted ? "Sign-in completed—you’re online" : "Portal completed automatically—you’re online"
                    )
                } else if result.status == 2 {
                    if var diagnostics = portalDiagnostics {
                        diagnostics.advance(phase: "stopped", title: "Portal submitted, but internet access did not return", terminal: true, reason: "connectivity_unverified")
                        diagnostics.save(to: SystemPaths.portalProgress)
                        portalDiagnostics = diagnostics
                    }
                    portalAttemptNeedsRetry = true
                    portalRetryAttemptedAt =
                        lastWebViewAttempt[fingerprint] ?? Date()
                    showMessage(
                        "Portal submitted, but internet access did not return"
                    )
                } else {
                    portalAttemptNeedsRetry = true
                    portalRetryAttemptedAt =
                        lastWebViewAttempt[fingerprint] ?? Date()
                    showMessage(
                        "Could not verify the rendered portal result"
                    )
                }
            case let .unsupported(reason):
                showMessage(
                    result.status == 0
                        ? ActivityLog.attentionDetail(for: reason)
                        : "Could not record the verification requirement"
                )
            case .failed:
                break
            }
        }
    }

    func monitoringCountdown(at date: Date) -> String {
        if let activeOperation {
            return activeOperation.progressText
        }
        guard serviceLoaded else {
            return "Automatic monitoring is off"
        }
        if needsManualLogin {
            // Don't show a countdown that implies auto-success is imminent —
            // it isn't. We still watch in the background so it clears the
            // moment they finish signing in.
            return "Sign in manually — still watching in the background"
        }
        if portalAttemptNeedsRetry {
            guard let attemptStartedAt = portalRetryAttemptedAt else {
                return "Attempt stopped — Check Now to retry"
            }
            let seconds = PortalRetrySchedule(
                interval: savedPreferences.interval
            ).remainingSeconds(
                after: attemptStartedAt,
                now: date
            )
            return seconds > 0
                ? "Attempt stopped — retrying portal in \(seconds)s"
                : "Retrying portal now…"
        }
        if state.lastResult == "CAPTIVE",
           state.consecutiveFailures == 0
        {
            return "Portal detected — signing in…"
        }
        if isBusy {
            return "Checking now…"
        }
        guard let timestamp = state.lastCheckTimestamp else {
            return "Waiting for the first automatic check"
        }
        let seconds = savedPreferences.interval.countdownSeconds(
            lastCheck: Date(timeIntervalSince1970: timestamp),
            now: date
        )
        if state.lastResult == "CAPTIVE" {
            let lastCheck = Date(timeIntervalSince1970: timestamp)
            if FastRetry.isActivelyRetrying(lastCheck: lastCheck, now: date) {
                let nextTry = FastRetry.secondsUntilNextTry(
                    lastCheck: lastCheck,
                    now: date
                )
                return nextTry > 0
                    ? "Signing in… next try in \(nextTry)s"
                    : "Signing in…"
            }
            return seconds > 0
                ? "Couldn’t sign in yet — next check in \(seconds)s"
                : "Retrying sign-in now…"
        }
        if state.lastResult == "NO_NETWORK", seconds == 0 {
            return "Next scheduled check is due"
        }
        return seconds > 0 ? "Rechecking in \(seconds)s" : "Checking now…"
    }

    var monitoringFactLabel: String {
        if needsManualLogin {
            return "Action needed"
        }
        if activeOperation != nil
            || (state.lastResult == "CAPTIVE" && !portalAttemptNeedsRetry)
        {
            return "Current attempt"
        }
        return "Next check"
    }

    var showsAttemptProgress: Bool {
        // No spinner once we've given up — a spinner reads as "still working".
        if needsManualLogin { return false }
        return activeOperation != nil
            || (state.lastResult == "CAPTIVE" && !portalAttemptNeedsRetry)
    }

    var checkNowIsDisabled: Bool {
        isQuitting || checkNowAvailability.isDisabled
    }

    var checkNowDisabledReason: String? {
        checkNowAvailability.disabledReason
    }

    private var checkNowAvailability: CheckNowAvailability {
        CheckNowAvailability(
            isBusy: isBusy,
            webViewIsActive: webViewAutopilot != nil,
            monitoringIsActive: serviceLoaded,
            lastResult: state.lastResult,
            consecutiveFailures: state.consecutiveFailures,
            portalAttemptNeedsRetry: portalAttemptNeedsRetry,
            activeOperation: activeOperation
        )
    }

    func testSpeedAgain() {
        startSpeedTest(automatic: false)
    }

    /// True once there is something to show — a committed reading or a test in
    /// flight. Until then the beans stay unlit rather than implying a "Single"
    /// tier for a venue that was never measured.
    var hasSpeedReading: Bool {
        isTestingCurrentConnection || connectionSpeedMeasurement != nil
    }

    var connectionSpeedMeasurement: SpeedMeasurement? {
        guard state.lastResult == "ONLINE", let gateway = state.gatewayMac,
              let measurement = speedMeasurement, measurement.gatewayMac == gateway,
              measurement.measuredAt.timeIntervalSince1970 >= (state.lastConnectionTimestamp ?? 0)
        else { return nil }
        return measurement
    }

    /// Download value the bean meter should render: the live ramp while testing,
    /// otherwise the committed measurement.
    var beanDownloadMbps: Double {
        guard state.lastResult == "ONLINE" else { return 0 }
        return isTestingCurrentConnection ? displayDownloadMbps : (connectionSpeedMeasurement?.downloadMbps ?? 0)
    }

    private func scheduleAutomaticSpeedTestIfNeeded() {
        guard automaticSpeedTestsEnabled,
              serviceLoaded,
              state.lastResult == "ONLINE",
              let connectionTimestamp = state.lastConnectionTimestamp,
              !isSpeedTesting
        else {
            return
        }
        if SpeedMeasurementStore.lastAutomaticConnectionTimestamp
            == connectionTimestamp
        {
            return
        }
        let gatewayAtSchedule = state.gatewayMac
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard automaticSpeedTestsEnabled,
                  serviceLoaded,
                  state.lastResult == "ONLINE",
                  state.gatewayMac == gatewayAtSchedule,
                  state.lastConnectionTimestamp == connectionTimestamp,
                  SpeedMeasurementStore.lastAutomaticConnectionTimestamp != connectionTimestamp,
                  !isSpeedTesting
            else {
                return
            }
            SpeedMeasurementStore.lastAutomaticConnectionTimestamp = connectionTimestamp
            startSpeedTest(automatic: true)
        }
    }

    private func startSpeedTest(automatic: Bool) {
        guard !automatic || automaticSpeedTestsEnabled else { return }
        guard !isSpeedTesting else { return }
        guard state.lastResult == "ONLINE" else {
            speedTestMessage = "Connect to the internet before testing speed"
            return
        }
        let gatewayAtStart = state.gatewayMac
        let connectionAtStart = state.lastConnectionTimestamp
        let attempt = "speed-" + UUID().uuidString
        let network = activityVenueDisplayName
        let joined = connectionAtStart.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? "unknown"
        let context = "\(network), connection started \(joined). "
        func trace(_ title: String, _ detail: String, _ status: String) {
            DiagnosticTrace.append(DiagnosticStep(attempt: attempt, phase: "quality", title: title,
                detail: context + detail, status: status), to: SystemPaths.logFile)
            refreshActivity()
        }
        let interfaceAtStart =
            CWWiFiClient.shared().interface()?.interfaceName ?? "en0"
        speedTestGatewayMac = gatewayAtStart
        speedTestConnectionTimestamp = connectionAtStart
        speedPhase = .measuring
        speedTestStartedAt = Date()
        displayDownloadMbps = 0
        speedTestMessage = ""
        speedTestFailed = false
        trace("Checking connection quality", "Internet access is confirmed. Measuring download, upload and responsiveness; this briefly uses network capacity.", "running")
        Task {
            let outcome = await Task.detached {
                SpeedTestRunner.outcome(
                    interface: interfaceAtStart,
                    gatewayMac: gatewayAtStart
                )
            }.value
            guard state.gatewayMac == gatewayAtStart, state.lastConnectionTimestamp == connectionAtStart,
                  state.lastResult == "ONLINE" else {
                endSpeedTest()
                speedTestMessage =
                    "Speed test stopped because the network changed"
                trace("Speed result discarded", "The connection changed during the test. No result was assigned to the new network.", "stopped")
                return
            }
            switch outcome {
            case let .success(measurement):
                trace(measurement.hasQualityConcern ? "Internet available, connection quality limited" : "Connection quality measured",
                      measurement.qualityMetrics, measurement.hasQualityConcern ? "warn" : "ok")
                trace("What this means", measurement.qualityAdvice, measurement.hasQualityConcern ? "warn" : "ok")
                await rampBeans(to: measurement, automatic: automatic)
            case let .failure(detail):
                endSpeedTest()
                speedTestMessage = detail
                speedTestFailed = true
                trace("Speed could not be measured", "Internet access passed its check, but the speed test did not finish: " + detail + ". Speed is unknown; the test service may be blocked or the connection may be struggling.", "warn")
            }
        }
    }

    /// Return to the idle state, reverting the live display to the last committed
    /// reading (or empty). Used when a test is abandoned or fails.
    private func endSpeedTest() {
        displayDownloadMbps = speedMeasurement?.downloadMbps ?? 0
        speedPhase = .idle
        speedTestStartedAt = nil
        speedTestGatewayMac = nil
        speedTestConnectionTimestamp = nil
    }

    /// Reveal the measured download with the coffee-roast ramp: ease the
    /// displayed value 0→target over ~1.7s with smoothstep so beans pop on
    /// one-by-one, then commit the real reading. Reduce Motion jumps straight to
    /// the final value and bean count.
    private func rampBeans(
        to measurement: SpeedMeasurement,
        automatic: Bool
    ) async {
        let target = measurement.downloadMbps
        speedPhase = .revealing
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            displayDownloadMbps = target
        } else {
            let duration: TimeInterval = 1.7
            let start = Date()
            while true {
                let elapsed = Date().timeIntervalSince(start)
                let p = min(1, elapsed / duration)
                displayDownloadMbps = target * (p * p * (3 - 2 * p))
                if p >= 1 { break }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
        guard state.gatewayMac == measurement.gatewayMac, state.lastResult == "ONLINE",
              measurement.measuredAt.timeIntervalSince1970 >= (state.lastConnectionTimestamp ?? 0) else {
            endSpeedTest()
            return
        }
        displayDownloadMbps = target
        speedMeasurement = measurement
        SpeedMeasurementStore.save(measurement)
        speedTestMessage = automatic
            ? "Tested automatically after connecting"
            : "Speed checked again"
        speedPhase = .idle
        speedTestStartedAt = nil
        speedTestGatewayMac = nil
        speedTestConnectionTimestamp = nil
    }

    private func updateOperationState() {
        isBusy = pendingServiceOperations > 0 || checkingConnection || verifyingAccess || previewOperation != nil
        activeOperation = verifyingAccess ? .verifyingAccess
            : checkingConnection ? .checkingConnection
            : pendingServiceOperations > 0 ? serviceOperation
            : portalOperation ?? previewOperation
    }
    private func enqueueServiceOperation(named name: ActiveOperation = .updatingMonitoring, _ operation: @escaping @MainActor () async -> Void) {
        guard !isQuitting else { return }
        pendingServiceOperations += 1
        if serviceOperation == nil { serviceOperation = name }
        updateOperationState()
        serviceRefreshTask?.cancel()
        serviceRefreshTask = nil
        let previous = serviceOperationTask
        serviceOperationTask = Task {
            await previous?.value
            serviceOperation = name
            updateOperationState()
            await operation()
            serviceLoaded = await serviceOperations.queryServiceLoaded()
            pendingServiceOperations -= 1
            if pendingServiceOperations == 0 {
                pendingMonitoringEnabled = nil
                serviceOperation = nil
                serviceOperationTask = nil
            }
            updateOperationState()
            if pendingServiceOperations == 0, deferredWebViewHandoff {
                let force = deferredForcedWebViewHandoff
                deferredWebViewHandoff = false
                deferredForcedWebViewHandoff = false
                considerWebViewHandoff(force: force)
            }
        }
    }

    #if DEBUG
    func setPortalOperationForTesting(_ active: Bool) {
        portalOperation = active ? .handlingPortal : nil
    }

    func setVerificationForTesting(_ active: Bool) {
        verifyingAccess = active
    }

    func considerWebViewHandoffForTesting(force: Bool = false) {
        considerWebViewHandoff(force: force)
    }

    var hasDeferredWebViewHandoffForTesting: Bool { deferredWebViewHandoff }

    func enqueueServiceOperationForTesting(_ operation: @escaping @MainActor () async -> Void) {
        enqueueServiceOperation(operation)
    }

    var pendingServiceOperationCountForTesting: Int { pendingServiceOperations }

    func waitForServiceOperations() async {
        await serviceOperationTask?.value
    }
    #endif

    var lastLoginText: String {
        guard let timestamp = state.lastLoginTimestamp else {
            return "Not yet"
        }
        return Date(timeIntervalSince1970: timestamp).formatted(
            date: .abbreviated,
            time: .standard
        )
    }
}

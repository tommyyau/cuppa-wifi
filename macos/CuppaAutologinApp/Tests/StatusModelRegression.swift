import AppKit
import Foundation

@main
@MainActor
enum StatusModelRegression {
    static func main() async throws {
        _ = NSApplication.shared
        // The runner supplies a temporary data directory. No installed Persona
        // or monitoring service is written by these checks.
        precondition(ProcessInfo.processInfo.environment["WIFI_AUTOLOGIN_DATA_DIR"] != nil)
        let defaults = UserDefaults(suiteName: "cuppa-status-regression-" + UUID().uuidString)!
        let service = EngineServiceOperations(sync: { false }, install: { _ in },
            runner: { _, _, _ in ProcessResult(status: 1, output: "", error: "not loaded") })
        let model = StatusModel(serviceOperations: service, defaults: defaults)
        var state = AgentState.unknown
        state.lastResult = "ONLINE"
        model.configureForVisualPreview(state: state, serviceLoaded: false)
        let original = model.portalIdentity
        model.identity.firstName = "Unsaved"
        model.identity.email = "unsaved@example.com"
        precondition(model.identityHasUnsavedChanges)
        precondition(model.portalIdentity == original)
        precondition(!model.statusSubtitle.contains("Unsaved"))
        model.discardIdentityChanges()
        precondition(model.identity == original)

        model.identity.firstName = "Saved"
        model.identity.email = "saved@example.com"
        let inFlightPersona = model.portalIdentity
        model.saveIdentity()
        precondition(!model.identityHasUnsavedChanges)
        precondition(model.portalIdentity.firstName == "Saved")
        precondition(IdentityStore.load() == model.portalIdentity)
        precondition(inFlightPersona == original)
        model.identity.firstName = "Another draft"
        precondition(model.portalIdentity.firstName == "Saved")
        model.discardIdentityChanges()
        precondition(model.identity.firstName == "Saved")

        // Settings edits take effect only after saving, and persist on reload.
        precondition(model.automaticSpeedTestsEnabled)
        model.preferences.automaticSpeedTests = false
        precondition(model.automaticSpeedTestsEnabled)
        model.identity.firstName = "Pending draft"
        model.setIgnorePersonalHotspots(false)
        precondition(model.automaticSpeedTestsEnabled)
        precondition(!model.preferences.automaticSpeedTests)
        precondition(IdentityStore.load().firstName == "Saved")
        precondition(!IdentityStore.load().ignoreHotspots)
        model.discardIdentityChanges()
        model.discardPreferenceChanges()
        precondition(model.preferences.automaticSpeedTests)
        model.preferences.automaticSpeedTests = false
        model.savePreferences()
        await model.waitForServiceOperations()
        precondition(!model.automaticSpeedTestsEnabled)
        precondition(!AgentPreferencesStore.load(identity: model.portalIdentity, defaults: defaults).automaticSpeedTests)
        precondition(!model.preferencesHaveUnsavedChanges)
        model.preferences.automaticSpeedTests = true
        model.discardPreferenceChanges()
        precondition(!model.preferences.automaticSpeedTests)

        // The everyday speed switch must not commit advanced or Persona drafts.
        let savedInterval = AgentPreferencesStore.load(identity: model.portalIdentity, defaults: defaults).interval
        model.preferences.interval = .fiveMinutes
        model.preferences.resetWiFiAfterFailures = true
        model.identity.firstName = "Still a draft"
        model.setAutomaticSpeedTests(true)
        precondition(model.automaticSpeedTestsEnabled)
        let reloaded = AgentPreferencesStore.load(identity: IdentityStore.load(), defaults: defaults)
        precondition(reloaded.interval == savedInterval)
        precondition(!reloaded.resetWiFiAfterFailures)
        precondition(IdentityStore.load().firstName == "Saved")
        precondition(model.preferences.interval == .fiveMinutes)
        precondition(model.preferencesHaveUnsavedChanges)
        model.discardPreferenceChanges()
        precondition(model.preferences.automaticSpeedTests)
        precondition(model.preferences.interval == savedInterval)
        model.discardIdentityChanges()

        // Failed disk writes leave advanced edits as drafts and preserve saved settings.
        model.configureForVisualPreview(state: state, serviceLoaded: false)
        let configDirectory = SystemPaths.sharedIdentityFile().deletingLastPathComponent()
        let configBackup = configDirectory.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: configDirectory, to: configBackup)
        try Data("blocking file".utf8).write(to: configDirectory)
        model.preferences.resetWiFiAfterFailures = true
        model.savePreferences()
        await model.waitForServiceOperations()
        precondition(model.preferencesHaveUnsavedChanges)
        precondition(model.message.contains("Could not apply advanced settings"))
        precondition(model.portalIdentity.reassociationEnabled == false)
        try FileManager.default.removeItem(at: configDirectory)
        try FileManager.default.moveItem(at: configBackup, to: configDirectory)
        precondition(!IdentityStore.load().reassociationEnabled)
        model.discardPreferenceChanges()

        // Log rotation, append, truncation and handoff creation must wake refresh.
        let temporary = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WIFI_AUTOLOGIN_DATA_DIR"]!)
        let observed = temporary.appendingPathComponent("observed.log")
        let handoff = temporary.appendingPathComponent("observed-handoff.json")
        var changes = FileChangeTracker()
        precondition(changes.hasChanges(at: [observed, handoff]))
        precondition(!changes.hasChanges(at: [observed, handoff]))
        try Data("first".utf8).write(to: observed)
        precondition(changes.hasChanges(at: [observed, handoff]))
        precondition(!changes.hasChanges(at: [observed, handoff]))
        try Data("first plus append".utf8).write(to: observed)
        precondition(changes.hasChanges(at: [observed, handoff]))
        try Data().write(to: observed)
        precondition(changes.hasChanges(at: [observed, handoff]))
        try Data("{}".utf8).write(to: handoff)
        precondition(changes.hasChanges(at: [observed, handoff]))
        let oldDate = (try FileManager.default.attributesOfItem(atPath: handoff.path))[.modificationDate]!
        try FileManager.default.moveItem(at: handoff, to: temporary.appendingPathComponent("rotated.json"))
        try Data("{}".utf8).write(to: handoff)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: handoff.path)
        precondition(changes.hasChanges(at: [observed, handoff]))
        try FileManager.default.removeItem(at: observed)
        precondition(changes.hasChanges(at: [observed, handoff]))
        state.lastResult = "NO_NETWORK"
        state.lastCheckTimestamp = Date().addingTimeInterval(-120).timeIntervalSince1970
        state.networkDiagnostic = NetworkDiagnostic(reason: "network_path_unavailable", title: "Likely network problem",
            detail: "No reachable portal. Try another network.", checks: "gateway_ping=no_reply", repeated: true,
            addressAssigned: true, consecutiveChecks: 2, checkedAt: Date().timeIntervalSince1970)
        model.configureForVisualPreview(state: state, serviceLoaded: true)
        precondition(model.statusTitle == "Network problem")
        precondition(model.statusSubtitle == "Likely network problem")
        precondition(model.monitoringCountdown(at: Date()) == "Next scheduled check is due")
        precondition(model.supportSummary.contains("No reachable portal. Try another network."))
        state.lastResult = "UNSUPPORTED"
        let unavailable = PortalDiagnostics(startedAt: Date().addingTimeInterval(-10).timeIntervalSince1970,
            updatedAt: Date().timeIntervalSince1970, phase: "stopped", title: "Wi-Fi sign-in page unavailable", terminal: true,
            reason: "portal_page_unavailable", detail: ActivityLog.attentionDetail(for: "portal_page_unavailable"))
        model.configureForVisualPreview(state: state, serviceLoaded: true, portalDiagnostics: unavailable)
        precondition(model.statusTitle == "Portal unavailable")
        precondition(model.statusSubtitle.contains("venue needs to check"))
        precondition(!model.statusSubtitle.contains("sign in yourself"))
        state.lastResult = "ONLINE"
        state.gatewayMac = "02:00:00:00:00:01"
        state.lastConnectionTimestamp = 1_000
        let slow = SpeedMeasurement(downloadMbps: 0.8, uploadMbps: 0.2, latencyMilliseconds: 600,
            measuredAt: Date(timeIntervalSince1970: 1_010), gatewayMac: state.gatewayMac, responsivenessRpm: 50)
        model.configureForVisualPreview(state: state, serviceLoaded: false, speedMeasurement: slow)
        precondition(model.connectionSpeedMeasurement?.hasQualityConcern == true)
        precondition(model.hasSpeedReading && model.beanDownloadMbps == slow.downloadMbps)
        state.lastResult = "CAPTIVE"
        model.configureForVisualPreview(state: state, serviceLoaded: false, speedMeasurement: slow)
        precondition(model.connectionSpeedMeasurement == nil)
        precondition(!model.hasSpeedReading && model.beanDownloadMbps == 0)
        state.lastResult = "ONLINE"
        state.lastConnectionTimestamp = 1_020
        model.configureForVisualPreview(state: state, serviceLoaded: false, speedMeasurement: slow)
        precondition(model.connectionSpeedMeasurement == nil) // old visit to the same network
        precondition(!model.hasSpeedReading && model.beanDownloadMbps == 0)
        state.gatewayMac = "02:00:00:00:00:02"
        model.configureForVisualPreview(state: state, serviceLoaded: false, speedMeasurement: slow)
        precondition(model.connectionSpeedMeasurement == nil) // phone must not inherit café quality
        precondition(!model.hasSpeedReading && model.beanDownloadMbps == 0)
        // A result or animation from an in-flight test belongs to its starting
        // session. Keep the process busy lock until it ends to avoid overlap.
        let phone = state
        for phase in [SpeedTestPhase.measuring, .revealing] {
            model.configureForVisualPreview(state: phone, serviceLoaded: false,
                speedMeasurement: slow, speedPhase: phase)
            precondition(model.isSpeedTesting && model.isTestingCurrentConnection)
            state.lastConnectionTimestamp = 1_030
            model.configureForVisualPreview(state: state, serviceLoaded: false,
                speedMeasurement: slow, speedPhase: phase, speedTestState: phone)
            precondition(model.isSpeedTesting && !model.isTestingCurrentConnection)
            precondition(!model.isMeasuringSpeed && !model.hasSpeedReading && model.beanDownloadMbps == 0)
        }
        try await serviceRegressions()
        print("Saved Persona, speed-test, network diagnostic and service regressions passed")
    }

    static func persistenceDuringApplyRegression() async throws {
        for fails in [false, true] {
            let defaults = UserDefaults(suiteName: "cuppa-apply-regression-" + UUID().uuidString)!
            let events = ServiceRecorder()
            let service = EngineServiceOperations(sync: { false }, install: { _ in
                events.record("install-start")
                Thread.sleep(forTimeInterval: 0.18)
                if fails { throw EngineInstallerError.installFailed("injected delayed failure") }
                events.record("install-end")
            }, runner: { _, _, _ in ProcessResult(status: 0, output: "", error: "") })
            let model = StatusModel(serviceOperations: service, defaults: defaults)
            model.configureForVisualPreview(state: .unknown, serviceLoaded: true)
            model.identity = IdentityStore.load()
            model.saveIdentity()
            let before = model.portalIdentity
            model.preferences.interval = .fiveMinutes
            model.preferences.resetWiFiAfterFailures = !before.reassociationEnabled
            model.savePreferences()
            precondition(model.persistentChangesDisabled)
            // Wait until Apply has written Persona flags and suspended in install.
            while !events.events.contains("install-start") { try await Task.sleep(for: .milliseconds(5)) }
            model.identity.firstName = "Editable draft during Apply"
            model.preferences.interval = .twoMinutes
            model.saveIdentity()
            model.setAutomaticSpeedTests(false)
            model.setIgnorePersonalHotspots(!before.ignoreHotspots)
            precondition(model.portalIdentity == before)
            precondition(model.automaticSpeedTestsEnabled)
            await model.waitForServiceOperations()
            let persisted = IdentityStore.load()
            precondition(persisted.firstName == before.firstName)
            precondition(persisted.ignoreHotspots == before.ignoreHotspots)
            precondition(persisted.reassociationEnabled == (fails ? before.reassociationEnabled : !before.reassociationEnabled))
            precondition(model.portalIdentity == persisted)
            precondition(model.identity.firstName == "Editable draft during Apply")
            precondition(model.preferences.interval == .twoMinutes)
            precondition(model.identityHasUnsavedChanges && model.preferencesHaveUnsavedChanges)
            let settings = AgentPreferencesStore.load(identity: persisted, defaults: defaults)
            precondition(settings.automaticSpeedTests)
            precondition(settings.interval == (fails ? .thirtySeconds : .fiveMinutes))
            precondition(!model.persistentChangesDisabled)
        }
    }

    /// The same production queue runs injected blocking work. No launchctl or
    /// installed preferences are touched by these regressions.
    static func serviceRegressions() async throws {
        let defaults = UserDefaults(suiteName: "cuppa-service-regression-" + UUID().uuidString)!
        defaults.set(false, forKey: "monitoringEnabled")
        let recorder = ServiceRecorder()
        let service = EngineServiceOperations(sync: {
            recorder.record("sync-start")
            Thread.sleep(forTimeInterval: 0.18)
            recorder.record("sync-end")
            return false
        }, install: { interval in
            recorder.record("install-\(interval.rawValue)")
        }, runner: { _, args, _ in
            recorder.record(args[0])
            return ProcessResult(status: 1, output: "", error: "injected failure")
        })
        let model = StatusModel(serviceOperations: service, defaults: defaults)
        model.bootstrap()
        // Saved data is available in the same event turn, before slow sync.
        precondition(model.portalIdentity == IdentityStore.load())
        precondition(model.isBusy && model.activeOperation == .starting)
        model.restartMonitoring() // duplicate toggle is ignored immediately
        model.preferences.interval = .fiveMinutes
        model.savePreferences() // duplicate Apply also ignored
        try await Task.sleep(for: .milliseconds(40))
        precondition(model.isBusy) // main actor kept delivering this heartbeat
        precondition(!recorder.events.contains("sync-end"))
        model.setVerificationForTesting(true)
        model.considerWebViewHandoffForTesting(force: true)
        precondition(model.hasDeferredWebViewHandoffForTesting)
        await model.waitForServiceOperations()
        precondition(!recorder.events.contains("install-300"))
        precondition(model.isBusy && model.activeOperation == .verifyingAccess)
        // Finishing service work cannot clear verification's ownership.
        model.setVerificationForTesting(false)
        model.considerWebViewHandoffForTesting()
        precondition(!model.hasDeferredWebViewHandoffForTesting)
        precondition(!model.isBusy)
        let stopped = await model.stopMonitoringForQuit()
        precondition(stopped)
        precondition(!defaults.bool(forKey: "monitoringEnabled"))

        // Queued UI work cannot clear the busy lock or release a portal handoff
        // while another owner or a later transaction remains active.
        var order: [String] = []
        model.enqueueServiceOperationForTesting {
            order.append("first-start")
            try? await Task.sleep(for: .milliseconds(40))
            order.append("first-end")
        }
        model.enqueueServiceOperationForTesting {
            precondition(model.isBusy)
            order.append("second")
        }
        model.considerWebViewHandoffForTesting(force: true)
        precondition(model.pendingServiceOperationCountForTesting == 2)
        await model.waitForServiceOperations()
        precondition(order == ["first-start", "first-end", "second"])
        precondition(!model.isBusy && !model.hasDeferredWebViewHandoffForTesting)

        let quitEvents = ServiceRecorder()
        let stoppable = EngineServiceOperations(sync: { false }, install: { _ in }, runner: { _, args, _ in
            quitEvents.record(args[0])
            let loaded = !quitEvents.events.contains("bootout")
            return ProcessResult(status: args[0] == "print" && !loaded ? 1 : 0, output: "", error: "")
        })
        defaults.set(true, forKey: "monitoringEnabled")
        let resumeModel = StatusModel(serviceOperations: stoppable, defaults: defaults)
        let quitStopped = await resumeModel.stopMonitoringForQuit()
        precondition(quitStopped && !resumeModel.serviceLoaded)
        precondition(defaults.bool(forKey: "monitoringEnabled"))

        // A whole transaction remains serialized even across independent callers.
        async let first = service.syncBundledEngine()
        try await Task.sleep(for: .milliseconds(20))
        async let second: Void = service.installService(interval: .oneMinute)
        _ = try await first
        try await second
        let events = recorder.events
        precondition(events.last == "install-60")
        precondition(events[events.count - 2] == "sync-end")

        let failures = ServiceRecorder()
        let loadedService = EngineServiceOperations(sync: { false }, install: { _ in
            failures.record("install")
            throw EngineInstallerError.installFailed("injected install failure")
        }, runner: { _, args, _ in
            failures.record(args[0])
            return ProcessResult(status: args[0] == "print" ? 0 : 1, output: "", error: "injected stop failure")
        })
        let failedModel = StatusModel(serviceOperations: loadedService, defaults: defaults)
        failedModel.configureForVisualPreview(state: .unknown, serviceLoaded: true)
        defaults.set(true, forKey: "monitoringEnabled")
        failedModel.setPortalOperationForTesting(true)
        failedModel.pauseMonitoring()
        precondition(failedModel.isBusy && !failedModel.monitoringEnabled)
        failedModel.pauseMonitoring()
        await failedModel.waitForServiceOperations()
        precondition(failedModel.serviceLoaded && failedModel.monitoringEnabled)
        precondition(failedModel.activeOperation == nil)
        precondition(defaults.bool(forKey: "monitoringEnabled"))
        precondition(failedModel.message.contains("Could not turn off"))
        precondition(failures.events.filter { $0 == "bootout" }.count == 1)
        let quitSucceeded = await failedModel.stopMonitoringForQuit()
        precondition(!quitSucceeded)
        precondition(failedModel.serviceLoaded)
        precondition(defaults.bool(forKey: "monitoringEnabled"))
        precondition(failedModel.message.contains("Could not stop"))

        let savedPersona = failedModel.portalIdentity
        let saved = AgentPreferencesStore.load(identity: savedPersona, defaults: defaults)
        failedModel.preferences.interval = .fiveMinutes
        failedModel.savePreferences()
        failedModel.savePreferences()
        await failedModel.waitForServiceOperations()
        precondition(failedModel.preferencesHaveUnsavedChanges)
        precondition(failedModel.portalIdentity == savedPersona)
        precondition(IdentityStore.load() == savedPersona)
        precondition(AgentPreferencesStore.load(identity: savedPersona, defaults: defaults) == saved)
        precondition(failedModel.message.contains("Could not apply advanced settings"))
        precondition(failures.events.filter { $0 == "install" }.count == 1) // duplicate Apply ignored
        try await persistenceDuringApplyRegression()
    }

}


private final class ServiceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ event: String) { lock.lock(); defer { lock.unlock() }; values.append(event) }
    var events: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

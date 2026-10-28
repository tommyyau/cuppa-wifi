import Foundation
import CuppaCore

@main
enum SelfTest {
    static func main() throws {
        // Exercise the actual ProcessRunner with a native child larger than both pipe buffers.
        if CommandLine.arguments.dropFirst().first == "--large-output-fixture" {
            FileHandle.standardOutput.write(Data(repeating: 111, count: 262144))
            FileHandle.standardError.write(Data(repeating: 101, count: 262144))
            return
        }
        testFrameCredentialBoundaries()
        testProductionPathOverrideFromEnvironment()
        let progressURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: progressURL) }
        var progress = PortalDiagnostics(startedAt: 100, updatedAt: 100,
            phase: "detected", title: "Captive portal detected")
        precondition(progress.isActive(at: Date(timeIntervalSince1970: 170)))
        precondition(!progress.isActive(at: Date(timeIntervalSince1970: 190)))
        for index in 0..<40 {
            progress.advance(phase: "form_analysis", title: "Page \(index)", now: Date(timeIntervalSince1970: 100 + Double(index)))
        }
        precondition(progress.isActive(at: Date(timeIntervalSince1970: 200)))
        progress.failureCode = -1009
        progress.advance(phase: "stopped", title: "Sign-in stopped", terminal: true,
            reason: "browser_network_unavailable", now: Date(timeIntervalSince1970: 140))
        progress.save(to: progressURL)
        precondition(PortalDiagnostics.load(from: progressURL) == progress)
        precondition(progress.events.count == 32)
        precondition(progress.elapsed(at: Date(timeIntervalSince1970: 200)) == 40)
        precondition(!progress.isActive(at: Date(timeIntervalSince1970: 110)))
        precondition(PortalLoadRetryPolicy.shouldRetry(code: -1009, retries: 0, actions: 0, pendingSubmission: false, remaining: 20))
        precondition(!PortalLoadRetryPolicy.shouldRetry(code: -1009, retries: 2, actions: 0, pendingSubmission: false, remaining: 20))
        precondition(!PortalLoadRetryPolicy.shouldRetry(code: -1009, retries: 0, actions: 1, pendingSubmission: false, remaining: 20))
        precondition(!PortalLoadRetryPolicy.shouldRetry(code: -1009, retries: 0, actions: 0, pendingSubmission: true, remaining: 20))
        precondition(!PortalLoadRetryPolicy.shouldRetry(code: -1202, retries: 0, actions: 0, pendingSubmission: false, remaining: 20))
        precondition(!PortalLoadRetryPolicy.shouldRetry(code: -1009, retries: 0, actions: 0, pendingSubmission: false, remaining: 2))
        let diagnostic = DiagnosticStep(attempt: "test", phase: "form", title: "Found form", detail: "https://portal.test/?token=secret user@example.com 07700900123", status: "ok", fields: [DiagnosticField(name: "email", label: "user@example.com", placeholder: "Email", type: "email", intent: "email", source: "JavaScript heuristic", category: "Persona email", maskedValue: "user@example.com")])
        let encoded = String(data: try JSONEncoder().encode(diagnostic), encoding: .utf8)!
        let traces = DiagnosticTrace.parse("malformed\nDIAGNOSTIC_STEP {bad}\nDIAGNOSTIC_STEP " + encoded + "\nDIAGNOSTIC_STEP " + encoded)
        precondition(traces.count == 1 && traces[0].steps.count == 1)
        let sanitizedTrace = String(data: try JSONEncoder().encode(traces[0].steps), encoding: .utf8)!
        precondition(!sanitizedTrace.contains("user@example.com"))
        precondition(!sanitizedTrace.contains("secret"))
        precondition(!sanitizedTrace.contains("07700900123"))
        precondition(traces[0].steps[0].fields[0].maskedValue == "[masked]")
        precondition(traces[0].steps[0].fields[0].confidence == nil)
        let diagnosticFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DiagnosticTrace.append(diagnostic, to: diagnosticFile)
        var completed = diagnostic
        completed.id = "probe"
        completed.phase = "probe"
        completed.title = "Probe: ONLINE"
        completed.fields = []
        DiagnosticTrace.append(completed, to: diagnosticFile)
        let written = try String(contentsOf: diagnosticFile, encoding: .utf8)
        precondition(DiagnosticTrace.parse(written).first?.steps.count == 2)
        precondition(ActivityLog.parse(written).isEmpty)
        try FileManager.default.removeItem(at: diagnosticFile)
        let data = Data(
            """
            {
              "ssid": null,
              "venue": "Coffee Shop",
              "gateway_mac": "02:00:00:00:00:01",
              "portal_domain": "portal.example",
              "last_result": "ONLINE",
              "last_login_ts": 946684800.5,
              "consecutive_failures": 0,
              "last_reassoc_ts": null
            }
            """.utf8
        )
        let state = try AgentStateLoader.decode(data)
        precondition(state.statusTitle == "Online")
        precondition(state.venue == "Coffee Shop")
        precondition(state.gatewayMac == "02:00:00:00:00:01")
        precondition(state.portalDomain == "portal.example")
        // Backward compatible: a state file without dhcp_domain decodes nil.
        precondition(state.dhcpDomain == nil)
        precondition(state.lastCheckTimestamp == nil)
        precondition(state.lastConnectionTimestamp == nil)
        precondition(state.lastLoginGatewayMac == nil)
        precondition(state.consecutiveFailures == 0)
        precondition(state.networkDiagnostic == nil)
        let offline = try AgentStateLoader.decode(Data("""
        {"last_result":"NO_NETWORK","consecutive_failures":0,"network_diagnostic":{
          "reason":"network_path_unavailable","title":"Likely network problem",
          "detail":"No portal is reachable. Try another network or ask the venue.",
          "checks":"gateway_ping=no_reply; direct_http=timeout","repeated":true,
          "address_assigned":true,"consecutive_checks":2,"checked_at":100}}
        """.utf8))
        precondition(offline.statusTitle == "Network problem")
        precondition(offline.networkDiagnostic?.consecutiveChecks == 2)
        let proxied = try AgentStateLoader.decode(Data("""
        {"last_result":"NO_NETWORK","consecutive_failures":0,"network_diagnostic":{
          "reason":"proxy_interference","title":"Direct Wi-Fi check blocked by a proxy",
          "detail":"A proxy cannot verify this Wi-Fi network.",
          "checks":"probes=apple:proxy_detected","consecutive_checks":1,"checked_at":100,
          "address_assigned":true,"repeated":true}}
        """.utf8))
        precondition(proxied.statusTitle == "Connection unverified")
        let networkEvents = ActivityLog.parse("2000-01-01 12:42:36,150 INFO network unavailable: reason=network_path_unavailable repeated=True gateway_mac=aa:bb:cc:dd:ee:ff")
        precondition(networkEvents.count == 1 && networkEvents[0].kind == .attention)
        let qualitySteps = [
            DiagnosticStep(attempt: "quality", phase: "quality", title: "Checking connection quality", detail: "Measuring", status: "running"),
            DiagnosticStep(attempt: "quality", timestamp: "2000-01-01T13:51:31.150Z", phase: "quality", title: "Internet available, connection quality limited", detail: "Example Guest Wi-Fi: 0.8 Mbps, 620 ms", status: "warn"),
            DiagnosticStep(attempt: "quality", phase: "quality", title: "What this means", detail: "Try another network", status: "warn"),
            DiagnosticStep(attempt: "other", phase: "form", title: "Filled form", detail: "Technical field trace", status: "ok")
        ]
        let qualityLog = try qualitySteps.map { "DIAGNOSTIC_STEP " + String(data: try JSONEncoder().encode($0), encoding: .utf8)! }.joined(separator: "\n")
        let qualityEvents = ActivityLog.parse(qualityLog)
        precondition(qualityEvents.count == 1 && qualityEvents[0].category == .quality)
        precondition(qualityEvents[0].detail.contains("Example Guest Wi-Fi"))
        precondition(qualityEvents[0].occurredAt != nil)
        var networkProgress = PortalDiagnostics(startedAt: 100, updatedAt: 130, phase: "network_unavailable", title: "Likely network problem", terminal: true)
        networkProgress.detail = "No reachable portal. Try another network."
        networkProgress.save(to: progressURL)
        precondition(PortalDiagnostics.load(from: progressURL)?.detail == networkProgress.detail)
        precondition(!networkProgress.isActive(at: Date(timeIntervalSince1970: 131)))

        var failedPortal = state
        failedPortal.lastResult = "CAPTIVE"
        failedPortal.consecutiveFailures = 1
        precondition(failedPortal.statusTitle == "Sign-in failed")

        let withDhcp = try AgentStateLoader.decode(Data(
            """
            {
              "gateway_mac": "00:00:0c:9f:f0:01",
              "dhcp_domain": "btwifi.com",
              "last_result": "ONLINE",
              "consecutive_failures": 0
            }
            """.utf8
        ))
        precondition(withDhcp.dhcpDomain == "btwifi.com")

        let missing = AgentStateLoader.load(
            from: URL(fileURLWithPath: "/definitely/missing/state.json")
        )
        precondition(missing == .unknown)

        let sarah = FakeIdentity.sarahChen
        precondition(sarah.firstName == "Sarah")
        precondition(sarah.lastName == "Chen")
        precondition(sarah.email.hasSuffix("@gmail.com"))
        precondition(sarah.phone.hasPrefix("07700900"))
        precondition(sarah.addressLine1 == "1 Example Street")
        precondition(sarah.country == "United Kingdom")
        precondition(sarah.gender == "Prefer not to say")

        for _ in 0 ..< 100 {
            let persona = FakeIdentity.generated()
            precondition(persona.email.hasSuffix("@gmail.com"))
            precondition(persona.phone.count == 11)
            precondition(persona.phone.hasPrefix("07700900"))
            precondition(!persona.city.isEmpty)
            precondition(!persona.reasonForVisit.isEmpty)
        }

        precondition(MonitoringInterval.thirtySeconds.rawValue == 30)
        let preferencesSuite = "wifi-autologin-preferences-" + UUID().uuidString
        let preferencesDefaults = UserDefaults(suiteName: preferencesSuite)!
        defer { preferencesDefaults.removePersistentDomain(forName: preferencesSuite) }
        var speedPreferences = AgentPreferencesStore.load(identity: sarah, defaults: preferencesDefaults)
        precondition(speedPreferences.automaticSpeedTests)
        speedPreferences.automaticSpeedTests = false
        AgentPreferencesStore.save(speedPreferences, defaults: preferencesDefaults)
        precondition(!AgentPreferencesStore.load(identity: sarah, defaults: preferencesDefaults).automaticSpeedTests)
        speedPreferences.automaticSpeedTests = true
        AgentPreferencesStore.save(speedPreferences, defaults: preferencesDefaults)
        precondition(AgentPreferencesStore.load(identity: sarah, defaults: preferencesDefaults).automaticSpeedTests)
        precondition(MonitoringInterval.oneMinute.label == "1 minute")
        precondition(MonitoringInterval(rawValue: 11) == nil)
        precondition(ActiveOperation.checkingConnection.title == "Checking Wi-Fi")
        precondition(
            ActiveOperation.handlingPortal.progressText.contains(
                "filling the form"
            )
        )
        precondition(
            ActiveOperation.verifyingAccess.disabledReason.contains(
                "internet access is being verified"
            )
        )
        let pausedCaptiveAvailability = CheckNowAvailability(
            isBusy: false,
            webViewIsActive: false,
            monitoringIsActive: false,
            lastResult: "CAPTIVE",
            consecutiveFailures: 0,
            portalAttemptNeedsRetry: false,
            activeOperation: nil
        )
        precondition(!pausedCaptiveAvailability.isDisabled)
        precondition(pausedCaptiveAvailability.disabledReason == nil)
        let monitoredCaptiveAvailability = CheckNowAvailability(
            isBusy: false,
            webViewIsActive: false,
            monitoringIsActive: true,
            lastResult: "CAPTIVE",
            consecutiveFailures: 0,
            portalAttemptNeedsRetry: false,
            activeOperation: nil
        )
        precondition(monitoredCaptiveAvailability.isDisabled)
        precondition(
            monitoredCaptiveAvailability.disabledReason?.contains(
                "automatic sign-in is already handling"
            ) == true
        )
        let checkDate = Date(timeIntervalSince1970: 1_000)
        precondition(
            MonitoringInterval.thirtySeconds.countdownSeconds(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_001)
            ) == 29
        )
        precondition(
            MonitoringInterval.thirtySeconds.countdownSeconds(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_031)
            ) == 0
        )
        let retrySchedule = PortalRetrySchedule(interval: .thirtySeconds)
        precondition(
            retrySchedule.remainingSeconds(
                after: checkDate,
                now: Date(timeIntervalSince1970: 1_001)
            ) == 29
        )
        precondition(
            !retrySchedule.isReady(
                after: checkDate,
                now: Date(timeIntervalSince1970: 1_029)
            )
        )
        precondition(
            retrySchedule.isReady(
                after: checkDate,
                now: Date(timeIntervalSince1970: 1_030)
            )
        )
        // FastRetry: while the engine is actively signing in (a fresh check),
        // the countdown reflects the ~6s fast-retry cadence, not the 30s tick.
        precondition(
            FastRetry.isActivelyRetrying(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_004)
            )
        )
        precondition(
            FastRetry.secondsUntilNextTry(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_002)
            ) == 4
        )
        precondition(
            FastRetry.secondsUntilNextTry(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_008)
            ) == 0
        )
        // A stale check (> activeWindow) means the fast-retry budget was spent;
        // we're idling until the next launchd tick, not fast-retrying.
        precondition(
            !FastRetry.isActivelyRetrying(
                lastCheck: checkDate,
                now: Date(timeIntervalSince1970: 1_013)
            )
        )
        // Manual-sign-in give-up rule: fail-closed (UNSUPPORTED) needs manual
        // sign-in at once; an ordinary CAPTIVE only after enough failures.
        precondition(
            ManualSignInPolicy.required(
                lastResult: "UNSUPPORTED",
                consecutiveFailures: 0,
                hasActiveOperation: false
            )
        )
        precondition(
            !ManualSignInPolicy.required(
                lastResult: "CAPTIVE",
                consecutiveFailures: 2,
                hasActiveOperation: false
            )
        )
        precondition(
            ManualSignInPolicy.required(
                lastResult: "CAPTIVE",
                consecutiveFailures: ManualSignInPolicy.failureThreshold,
                hasActiveOperation: false
            )
        )
        // Never while an attempt is actively in flight, and never when online.
        precondition(
            !ManualSignInPolicy.required(
                lastResult: "UNSUPPORTED",
                consecutiveFailures: 9,
                hasActiveOperation: true
            )
        )
        precondition(
            !ManualSignInPolicy.required(
                lastResult: "ONLINE",
                consecutiveFailures: 9,
                hasActiveOperation: false
            )
        )
        precondition(
            ConnectionDurationFormatter.string(
                from: Date(timeIntervalSince1970: 1_000),
                to: Date(timeIntervalSince1970: 11_457)
            ) == "2h 54m 17s"
        )
        precondition(
            ConnectionDurationFormatter.string(
                from: Date(timeIntervalSince1970: 2_000),
                to: Date(timeIntervalSince1970: 1_000)
            ) == "0h 0m 0s"
        )

        let speed = try SpeedTestRunner.parse(
            Data(
                """
                {
                  "dl_throughput": 1475939,
                  "ul_throughput": 18412700,
                  "base_rtt": 644.7
                }
                """.utf8
            ),
            gatewayMac: "02:00:00:00:00:01",
            measuredAt: Date(timeIntervalSince1970: 1_000)
        )
        precondition(abs(speed.downloadMbps - 1.475939) < 0.000001)
        precondition(abs(speed.uploadMbps - 18.4127) < 0.000001)
        precondition(speed.compactSummary.contains("↓ 1.5"))
        precondition(speed.uploadSummary == "18")
        precondition(speed.hasQualityConcern)
        precondition(speed.qualityAdvice.contains("Limited download speed"))
        precondition(speed.qualityAdvice.contains("High idle latency"))
        precondition(speed.qualityMetrics.contains("645 ms"))
        let responsive = SpeedMeasurement(downloadMbps: 50, uploadMbps: 10, latencyMilliseconds: 20,
            measuredAt: Date(), gatewayMac: "test", responsivenessRpm: 500)
        precondition(!responsive.hasQualityConcern)
        var laggy = responsive
        laggy.responsivenessRpm = 80
        precondition(laggy.hasQualityConcern && laggy.qualityAdvice.contains("under load"))
        let timeoutStart = Date()
        precondition(ProcessRunner.run("/bin/sleep", ["5"], timeout: 0.1).status == 124)
        precondition(Date().timeIntervalSince(timeoutStart) < 3)
        precondition(ProcessRunner.run("/usr/bin/true", [], timeout: 1).status == 0)
        // Both streams exceed pipe capacity: waiting for exit before draining
        // used to turn a successful verbose command into a timeout or deadlock.
        let verbose = ProcessRunner.run(CommandLine.arguments[0], ["--large-output-fixture"], timeout: 5)
        precondition(verbose.status == 0)
        precondition(verbose.output == String(repeating: "o", count: 262144))
        precondition(verbose.error == String(repeating: "e", count: 262144))
        var localTime = diagnostic
        localTime.timestamp = "2000-01-01T13:51:31.123+00:00"
        // Match the platform's local-time rendering, including fractional ISO timestamps.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        precondition(localTime.displayTime == iso.date(from: localTime.timestamp)!.formatted(date: .omitted, time: .standard))

        let activity = ActivityLog.parse(
            """
            2000-01-01 11:41:22,126 INFO captive portal detected: venue=coffee.example portal_domain=coffee.example
            2000-01-01 11:41:25,447 INFO auto-login succeeded: venue=Coffee Shop source=apple gateway_mac=02:00:00:00:00:04
            2000-01-01 11:41:55,000 DEBUG online (source=apple)
            2000-01-01 11:42:10,000 INFO connection established: venue=Example Cinema Wi-Fi source=apple gateway_mac=02:00:00:00:00:05
            2000-01-01 11:43:10,000 WARNING login failed (1 consecutive, reason=privacy_email_required), captured to /private/capture
            2000-01-01 11:44:10,000 WARNING login failed (1 consecutive, reason=required_field_unmapped:favourite_dinosaur), captured to /private/capture
            2000-01-01 11:45:10,000 INFO webview detected unsupported portal: venue=Arcade reason=captcha_required
            """
        )
        precondition(activity.count == 6)
        precondition(activity[0].title == "Portal detected")
        precondition(activity[0].detail == "Signing in at coffee.example")
        precondition(activity[1].title == "Connected automatically")
        precondition(activity[1].detail.contains("Coffee Shop"))
        precondition(activity[1].category == .automaticSignIn)
        precondition(activity[1].occurredAt != nil)
        precondition(
            activity[1].gatewayMac == "02:00:00:00:00:04"
        )
        precondition(activity[2].title == "Connected successfully")
        precondition(activity[2].detail.contains("Example Cinema Wi-Fi"))
        precondition(activity[2].category == .connection)
        precondition(
            activity[2].gatewayMac == "02:00:00:00:00:05"
        )
        precondition(activity[3].title == "Sign-in needs attention")
        precondition(activity[3].detail.contains("privacy relay"))
        precondition(activity[4].detail.contains("unfamiliar required field"))
        precondition(activity[5].title == "Sign-in needs verification")
        precondition(activity[5].detail.contains("CAPTCHA"))
        let webViewActivity = ActivityLog.parse(
            """
            2000-01-01 12:00:00,000 INFO webview auto-login succeeded: venue=Example Coffee source=apple gateway_mac=02:00:00:00:00:06
            """
        )
        precondition(webViewActivity.count == 1)
        precondition(
            webViewActivity[0].category == .automaticSignIn
        )

        let handoffData = Data(
            """
            {
              "portal_url": "http://portal.example/login",
              "venue_fingerprint": "portal.example",
              "reason": "js_render",
              "captured_html_path": null,
              "written_at": 1000,
              "network_interface": "en0",
              "network_gateway_ip": "192.0.2.1"
            }
            """.utf8
        )
        let handoff = try JSONDecoder().decode(
            WebViewHandoffRecord.self,
            from: handoffData
        )
        precondition(handoff.validatedPortalURL?.host == "portal.example")
        let escapedHandoff = WebViewHandoffRecord(
            portalURL: "https://portal.example/login?ssid=Example Guest&continue=http%3A%2F%2Fcaptive.apple.com%2F",
            venueFingerprint: nil, reason: "requires_browser", capturedHTMLPath: nil, writtenAt: 100)
        precondition(escapedHandoff.validatedPortalURL?.absoluteString == "https://portal.example/login?ssid=Example%20Guest&continue=http%3A%2F%2Fcaptive.apple.com%2F")
        precondition(handoff.networkInterface == "en0")
        precondition(handoff.networkGatewayIP == "192.0.2.1")
        let legacyHandoff = try JSONDecoder().decode(WebViewHandoffRecord.self,
            from: Data("{\"portal_url\":\"http://portal.example/login\",\"reason\":\"js_render\",\"written_at\":1000}".utf8))
        precondition(legacyHandoff.networkInterface == nil)
        let ambiguousGrantHandoff = WebViewHandoffRecord(
            portalURL: "https://eu.network-auth.com/splash/costa/",
            venueFingerprint: "02:00:00:00:00:01",
            reason: "meraki_grant_transport_ambiguous",
            capturedHTMLPath: nil,
            writtenAt: 1_000
        )
        precondition(
            ambiguousGrantHandoff.validatedPortalURL?.host
                == "eu.network-auth.com"
        )
        let unreviewedHandoff = WebViewHandoffRecord(
            portalURL: "https://portal.example/login",
            venueFingerprint: nil,
            reason: "arbitrary_failure",
            capturedHTMLPath: nil,
            writtenAt: 1_000
        )
        precondition(unreviewedHandoff.validatedPortalURL == nil)
        precondition(
            handoff.isFresh(
                now: Date(timeIntervalSince1970: 1_030),
                maxAge: 90
            )
        )
        precondition(
            !handoff.isFresh(
                now: Date(timeIntervalSince1970: 1_091),
                maxAge: 90
            )
        )
        var captiveState = AgentState.unknown
        captiveState.portalDomain = "portal.example"
        precondition(handoff.matches(captiveState))
        captiveState.portalDomain = "different.example"
        precondition(!handoff.matches(captiveState))

        let decodedJSResult = WebViewAutopilotResult.decode(
            [
                "status": "unsupported",
                "detail": "captcha_required",
            ]
        )
        precondition(decodedJSResult?.status == .unsupported)
        precondition(decodedJSResult?.detail == "captcha_required")
        precondition(decodedJSResult?.venue == nil)
        let decodedPretResult = WebViewAutopilotResult.decode(
            [
                "status": "submitted",
                "detail": "submitted after 2 steps",
                "venue": "Pret",
            ]
        )
        precondition(decodedPretResult?.venue == "Pret")
        precondition(
            WebViewAutopilotResult.decode(["status": "invented"]) == nil
        )

        let rejection = WebViewAutopilotResult.decode(["status": "needs_more", "detail": ["fieldsStillFailing": [["intent": "email", "name": "email", "type": "email"]], "emailIdentityRejected": true]])
        precondition(rejection?.emailIdentityRejected == true)
        precondition(rejection?.fieldsStillFailing.first?.intent == "email")
        precondition(rejection?.detail.contains("configured email") == true)
        precondition(PortalJourney.decode(["actions": 1, "trace": [], "attempts": ["abcdef12:1234abcd": true]])?.actions == 1)
        precondition(PortalJourney.decode(["actions": 100, "trace": [], "attempts": [:]]) == nil)
        precondition(PortalJourney.decode(["actions": 1, "trace": [], "attempts": ["private@example.com": true]]) == nil)

        var cacheState = AgentState.unknown
        cacheState.gatewayMac = "02:00:00:00:00:01"
        precondition(!NetworkNameCache.canStore("Phone", state: cacheState))
        cacheState.ssid = "Cafe Guest"
        precondition(!NetworkNameCache.canStore("Phone", state: cacheState))
        precondition(NetworkNameCache.canStore("Cafe Guest", state: cacheState))
        cacheState.gatewayMac = "00:00:5e:00:01:01"
        precondition(!NetworkNameCache.canStore("Cafe Guest", state: cacheState))
        precondition(NetworkNameCache.key(for: "test") != "venue.test")

        var networkNameDelay = NetworkNameRefreshDelay()
        let networkChangeTime = Date(timeIntervalSince1970: 1_000)
        networkNameDelay.noteGatewayChange(
            to: "aa:bb:cc:dd:ee:ff",
            now: networkChangeTime,
            delay: 3
        )
        precondition(
            networkNameDelay.shouldDefer(
                gateway: "aa:bb:cc:dd:ee:ff",
                now: networkChangeTime.addingTimeInterval(2)
            )
        )
        precondition(
            !networkNameDelay.shouldDefer(
                gateway: "aa:bb:cc:dd:ee:ff",
                now: networkChangeTime.addingTimeInterval(4)
            )
        )

        var previousCaptive = AgentState.unknown
        previousCaptive.lastResult = "CAPTIVE"
        previousCaptive.gatewayMac = "aa:bb:cc:dd:ee:ff"
        var verifiedOnline = previousCaptive
        verifiedOnline.lastResult = "ONLINE"
        verifiedOnline.lastLoginTimestamp = 1_000
        verifiedOnline.lastCheckTimestamp = 1_000
        verifiedOnline.lastLoginGatewayMac = "aa:bb:cc:dd:ee:ff"
        var dismissalGate = CaptivePortalDismissalGate()
        precondition(
            dismissalGate.shouldDismiss(
                previous: previousCaptive,
                refreshed: verifiedOnline,
                now: Date(timeIntervalSince1970: 1_005)
            )
        )
        precondition(
            !dismissalGate.shouldDismiss(
                previous: verifiedOnline,
                refreshed: verifiedOnline,
                now: Date(timeIntervalSince1970: 1_006)
            )
        )
        var staleOnline = verifiedOnline
        staleOnline.lastLoginTimestamp = 1_001
        staleOnline.lastCheckTimestamp = 1_001
        precondition(
            !dismissalGate.shouldDismiss(
                previous: previousCaptive,
                refreshed: staleOnline,
                now: Date(timeIntervalSince1970: 2_000)
            )
        )
        var mismatchedGateway = verifiedOnline
        mismatchedGateway.gatewayMac = "aa:bb:cc:dd:ee:00"
        precondition(
            !dismissalGate.shouldDismiss(
                previous: previousCaptive,
                refreshed: mismatchedGateway,
                now: Date(timeIntervalSince1970: 1_005)
            )
        )

        // Costa: grant was ambiguous, but the following probe verified access.
        var costaOnline = verifiedOnline
        costaOnline.lastLoginTimestamp = nil
        costaOnline.lastLoginGatewayMac = nil
        costaOnline.lastCheckTimestamp = 1_030
        precondition(dismissalGate.shouldDismiss(previous: previousCaptive, refreshed: costaOnline,
                                                now: Date(timeIntervalSince1970: 1_031)))
        precondition(!dismissalGate.shouldDismiss(previous: costaOnline, refreshed: costaOnline,
                                                 now: Date(timeIntervalSince1970: 1_032)))
        var nextProbe = costaOnline
        nextProbe.lastCheckTimestamp = 1_060
        precondition(dismissalGate.shouldDismiss(previous: costaOnline, refreshed: nextProbe,
                                                now: Date(timeIntervalSince1970: 1_061)))
        nextProbe.lastResult = "CAPTIVE"
        precondition(!dismissalGate.shouldDismiss(previous: costaOnline, refreshed: nextProbe,
                                                 now: Date(timeIntervalSince1970: 1_061)))

        let lockDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let lockURL = lockDirectory.appendingPathComponent("engine.lock")
        let firstLock = SharedEngineLock.acquire(at: lockURL)
        precondition(firstLock != nil)
        precondition(SharedEngineLock.acquire(at: lockURL) == nil)
        firstLock?.release()
        let reacquiredLock = SharedEngineLock.acquire(at: lockURL)
        precondition(reacquiredLock != nil)
        reacquiredLock?.release()
        try? FileManager.default.removeItem(at: lockDirectory)

        // Shared/virtual gateway MACs must not be treated as a venue
        // identity (the Nando's-name-at-Picturehouse collision).
        precondition(GatewayMAC.isShared("00:00:0c:9f:f0:01"))   // HSRPv2
        precondition(GatewayMAC.isShared("00:00:0c:9f:f0:02"))   // HSRPv2
        precondition(GatewayMAC.isShared("00:00:0c:07:ac:01"))   // HSRPv1
        precondition(GatewayMAC.isShared("00:07:b4:00:00:01"))   // GLBP
        precondition(GatewayMAC.isShared("00:00:5e:00:01:01"))   // VRRP
        precondition(!GatewayMAC.isShared("02:00:00:00:00:01"))  // LAA gateway: still a venue identity
        precondition(!GatewayMAC.isShared("a8:46:9d:00:00:01"))  // synthetic device suffix, ordinary vendor OUI
        precondition(!GatewayMAC.isShared("98:18:88:00:00:01"))  // synthetic device suffix, ordinary vendor OUI
        precondition(!GatewayMAC.isShared("00:00:0c:00:00:01"))  // synthetic Cisco suffix outside the shared pools
        precondition(!GatewayMAC.isShared(nil))
        precondition(!GatewayMAC.isShared("not-a-mac"))

        // A WebView handoff must never match on a shared/virtual gateway MAC
        // (cross-venue leak), but must still match on a real MAC or the
        // portal domain.
        func makeHandoff(_ fingerprint: String?) -> WebViewHandoffRecord {
            WebViewHandoffRecord(
                portalURL: "https://portal.example/x",
                venueFingerprint: fingerprint,
                reason: "js_render",
                capturedHTMLPath: nil,
                writtenAt: 0
            )
        }
        var sharedState = AgentState.unknown
        sharedState.gatewayMac = "00:00:0c:9f:f0:01"
        precondition(!makeHandoff("00:00:0c:9f:f0:01").matches(sharedState))
        var realState = AgentState.unknown
        realState.gatewayMac = "a8:46:9d:00:00:01"
        precondition(makeHandoff("a8:46:9d:00:00:01").matches(realState))
        var domainState = AgentState.unknown
        domainState.gatewayMac = "00:00:0c:9f:f0:01"
        domainState.portalDomain = "eu.network-auth.com"
        precondition(makeHandoff("eu.network-auth.com").matches(domainState))

        // The model is advisory; only bounded, observed IDs and allowlisted
        // meanings may cross into the browser executor.
        let field = PortalReasoningRequest.Field(key: "f0", label: "Prénom", name: "opaque", type: "text", context: "Guest registration")
        func request(mode: String = "fields", fields: [PortalReasoningRequest.Field]? = nil,
                     choices: [PortalReasoningRequest.Choice] = [], context: String = "Guest Wi-Fi") -> PortalReasoningRequest {
            .init(id: "r1", mode: mode, signature: "abcdef12", context: context,
                  fields: fields ?? [field], choices: choices, target: "")
        }
        let classification = request()
        precondition(classification.isValid)
        let classificationJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(classification))
        precondition(PortalReasoningRequest.decode(classificationJSON) != nil)
        var reviewed = classification
        reviewed.review = .init(strategy: "translate", previousIntent: "unknown", rejected: false, alternatives: [], nearbyFields: [])
        let reviewedJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(reviewed))
        precondition(PortalReasoningRequest.decode(reviewedJSON)?.review?.strategy == "translate")
        reviewed.review = .init(strategy: "execute", previousIntent: nil, rejected: false, alternatives: [], nearbyFields: [])
        precondition(!reviewed.isValid)
        reviewed.review = .init(strategy: "compare", previousIntent: "invented", rejected: true, alternatives: [], nearbyFields: [])
        precondition(!reviewed.isValid)
        reviewed.review = .init(strategy: "compare", previousIntent: "full_name", rejected: true, alternatives: ["full_name"], nearbyFields: [String(repeating: "x", count: 181)])
        precondition(!reviewed.isValid)
        precondition(!request(fields: [field, field]).isValid)
        precondition(!request(fields: [field, .init(key: "f1", label: "Surname", name: "surname", type: "text", context: "")]).isValid)
        precondition(!request(context: String(repeating: "x", count: 601)).isValid)
        precondition(!request(mode: "execute").isValid)
        precondition(PortalReasoningRequest.decode(["mode": "fields"]) == nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "first_name")]).validated(for: classification) != nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "first_name", translation: "First name and surname")]).validated(for: classification) != nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "first_name", translation: String(repeating: "x", count: 241))]).validated(for: classification) == nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "first_name", translatedDescription: String(repeating: "x", count: 241))]).validated(for: classification) == nil)
        precondition(!request(fields: [.init(key: "f0", label: "Name", name: "x", type: "text", context: "", description: String(repeating: "x", count: 241))]).isValid)
        precondition(PortalReasoningDecision(fields: [.init(key: "f99", intent: "first_name")]).validated(for: classification) == nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "password")]).validated(for: classification) == nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "first_name"), .init(key: "f0", intent: "email")]).validated(for: classification) == nil)
        let actionRequest = request(mode: "action", fields: [], choices: [.init(key: "a0", label: "Proceed", value: "")])
        precondition(PortalReasoningDecision(choice: "a0").validated(for: actionRequest) != nil)
        precondition(PortalReasoningDecision(choice: "a1").validated(for: actionRequest) == nil)
        precondition(PortalReasoningDecision(fields: [.init(key: "f0", intent: "email")]).validated(for: actionRequest) == nil)
        precondition(PortalReasoningDecision(choice: "a0").validated(for: classification) == nil)
        precondition(PortalReasoningDecision().validated(for: actionRequest) != nil) // Explicit abstention.
        var returningRequest = actionRequest
        returningRequest.accountOperation = "existing"
        precondition(returningRequest.isValid)
        returningRequest.accountOperation = "claimed_by_page"
        precondition(!returningRequest.isValid)

        let account = PortalCredentials(origin: "https://portal.example", operation: .create, username: "chosen", password: "secret")
        precondition(account.authorizes(URL(string: "https://portal.example/login")!))
        precondition(!account.authorizes(URL(string: "http://portal.example/login")!))
        precondition(!account.authorizes(URL(string: "https://other.example/login")!))
        precondition(!account.authorizes(URL(string: "https://portal.example:444/login")!))
        let accountDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: accountDirectory) }
        let store = PortalAccountStore(file: accountDirectory.appendingPathComponent("accounts.json"))
        let loginURL = URL(string: "https://portal.example/login")!
        precondition(store.load(for: loginURL, scope: "venue-a") == nil)
        try! store.remember(account, scope: "venue-a")
        let reloadedStore = PortalAccountStore(file: store.file)
        precondition(reloadedStore.load(for: loginURL, scope: "venue-a")?.operation == .existing)
        precondition(reloadedStore.load(for: loginURL, scope: "venue-a")?.password == "secret")
        precondition(reloadedStore.load(for: loginURL, scope: "venue-b") == nil)
        precondition(reloadedStore.load(for: loginURL, scope: nil) == nil)
        precondition(reloadedStore.load(for: URL(string: "http://portal.example/login")!, scope: "venue-a") == nil)
        precondition(reloadedStore.load(for: URL(string: "https://other.example/login")!, scope: "venue-a") == nil)
        try! FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.file.path)
        precondition(reloadedStore.load(for: loginURL, scope: "venue-a") == nil)
        let exhausted = WebViewAutopilotResult.decode(["status": "unsupported", "detail": ["reason": "validation_exhausted", "emailIdentityRejected": true]])!
        precondition(exhausted.detail == "validation_exhausted" && exhausted.emailIdentityRejected)
        print("Swift self-tests: PASS")
    }
    static func testFrameCredentialBoundaries() {
        let persona = FakeIdentity.sarahChen
        let authorizedAccount: [String: Any] = ["operation": "existing", "username": "fixture@example.test", "password": "explicit-fixture-secret"]
        let unauthorizedFrame = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: true)
        precondition((unauthorizedFrame["identity"] as? [String: Any])?["password"] == nil,
                     "Unauthorized subframes must not receive the Persona password")
        precondition((unauthorizedFrame["credentials"] as? [String: Any])?.isEmpty == true)
        let authorizedFrame = PortalAutofillPayload.make(identity: persona, credentials: authorizedAccount, isSubframe: true,
            frameOrigin: "https://account.test:443", mainOrigin: "https://portal.test:443")
        precondition((authorizedFrame["credentials"] as? [String: Any])?["password"] as? String == "explicit-fixture-secret")
        precondition((authorizedFrame["identity"] as? [String: Any])?["password"] == nil)
        let mainFrame = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: false)
        precondition((mainFrame["identity"] as? [String: Any])?["password"] as? String == persona.password)
        let sameOriginFrame = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: true,
            frameOrigin: "https://portal.test:443", mainOrigin: "https://portal.test:443")
        precondition((sameOriginFrame["identity"] as? [String: Any])?["password"] as? String == persona.password)
        let crossOriginFrame = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: true,
            frameOrigin: "https://third-party.test:443", mainOrigin: "https://portal.test:443")
        precondition((crossOriginFrame["identity"] as? [String: Any])?["password"] == nil)
        let signupFrame = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: true,
            frameOrigin: "https://signup.test:443", mainOrigin: "https://portal.test:443",
            signupOrigin: "https://signup.test:443")
        precondition((signupFrame["identity"] as? [String: Any])?["password"] as? String == persona.password)
        let differentPort = PortalAutofillPayload.make(identity: persona, credentials: [:], isSubframe: true,
            frameOrigin: "https://portal.test:444", mainOrigin: "https://portal.test:443")
        precondition((differentPort["identity"] as? [String: Any])?["password"] == nil)
        for inherited in ["about:blank", "about:srcdoc"] {
            let url = PortalFrameURL.make(scheme: "https", host: "signup.test", port: 443,
                requestURL: URL(string: inherited), mainURL: URL(string: "https://portal.test/register/new"))!
            precondition(url.host == "signup.test")
            precondition(PortalFrameURL.isSignup(url))
            precondition(!PortalCredentials(origin: "https://portal.test", operation: .create,
                username: "user", password: "secret").authorizes(url))
        }
        let requestedSignup = PortalFrameURL.make(scheme: "https", host: "signup.test", port: 443,
            requestURL: URL(string: "https://other.test/signup"), mainURL: URL(string: "https://portal.test/login"))!
        precondition(requestedSignup.host == "signup.test" && PortalFrameURL.isSignup(requestedSignup))
        for host in ["::1", "2001:db8:85a3::8a2e:370:7334"] {
            let url = PortalFrameURL.make(scheme: "http", host: host, port: 8080,
                requestURL: URL(string: "about:blank"), mainURL: URL(string: "http://portal.test/register"))!
            precondition(url.absoluteString == "http://[\(host)]:8080/register")
            precondition(PortalFrameURL.isSignup(url))
            precondition(PortalCredentials(origin: "http://[\(host)]:8080", operation: .create,
                username: "user", password: "secret").authorizes(url))
        }
        for scheme in ["", "data", "file", "about"] {
            precondition(PortalFrameURL.make(scheme: scheme, host: "", port: 0,
                requestURL: URL(string: "about:blank"), mainURL: URL(string: "https://portal.test/signup")) == nil)
        }
    }

    static func testProductionPathOverrideFromEnvironment() {
        // The runner starts this child with a distinct temporary override; no shared process
        // environment is mutated, and ignoring the environment cannot accidentally pass.
        guard let override = ProcessInfo.processInfo.environment["WIFI_AUTOLOGIN_DATA_DIR"], !override.isEmpty else {
            preconditionFailure("SelfTest requires its isolated data-root environment")
        }
        precondition(EnginePaths().root == URL(fileURLWithPath: override))
        precondition(EnginePaths().root != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/wifi-autologin"))
    }
}

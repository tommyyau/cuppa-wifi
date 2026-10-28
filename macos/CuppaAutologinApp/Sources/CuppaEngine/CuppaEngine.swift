import CuppaCore
import CuppaNetworking
import CuppaPortals
import Foundation

/// Coordinates one bounded detect → portal → independently verify cycle.
/// All external effects are injectable. Neither portal HTML nor model output can
/// directly write ONLINE, and results are re-scoped after every network operation.
public actor CuppaEngine {
    public typealias ClientFactory = @Sendable (NetworkSnapshot) -> any HTTPClient
    public typealias PortalFactory = @Sendable (any HTTPClient) -> any PortalHandling
    public typealias Diagnosis =
        @Sendable (any HTTPClient, NetworkSnapshot, [String]) async -> NetworkDiagnosis
    public static let unsupportedReasons: Set<String> = [
        "captcha_required", "verification_code_required", "voucher_or_venue_credential_required",
        "sponsor_approval_required", "government_identity_required", "marketing_consent_required",
        "social_login_required", "account_credentials_required", "unknown_required_field",
        "payment_required", "email_verification", "sms_verification", "two_factor",
        "validation_exhausted", "connectivity_unverified", "portal_page_unavailable",
        "persona_phone_rejected", "privacy_email_required",
    ]
    public let paths: EnginePaths
    private let inspector: any NetworkInspecting
    private let clientFactory: ClientFactory
    private let portalFactory: PortalFactory
    private let diagnose: Diagnosis
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let reassociate: @Sendable (String) async -> Void
    private let discover: @Sendable (String?) async -> URL?
    private let forensics: @Sendable (NetworkSnapshot, any HTTPClient, URL?, String) async -> URL?
    private let evidence: EvidenceStore
    private let handoffs: BrowserHandoffStore

    public init(
        paths: EnginePaths = EnginePaths(), resources: URL,
        inspector: any NetworkInspecting = NativeNetworkInspector(),
        clientFactory: @escaping ClientFactory = { NativeHTTPClient(network: $0) },
        portalFactory: PortalFactory? = nil, diagnose: Diagnosis? = nil,
        now: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
        },
        reassociate: (@Sendable (String) async -> Void)? = nil,
        discover: (@Sendable (String?) async -> URL?)? = nil,
        forensics: (@Sendable (NetworkSnapshot, any HTTPClient, URL?, String) async -> URL?)? = nil
    ) {
        self.paths = paths
        self.inspector = inspector
        self.clientFactory = clientFactory
        self.portalFactory =
            portalFactory ?? {
                PortalWorkflow(client: $0, resources: resources, dataDirectory: paths.root)
            }
        self.diagnose =
            diagnose ?? { client, network, errors in
                await NetworkDiagnostics(client: client, network: network).diagnose(
                    errors: errors,
                    progress: { title, detail in
                        EvidenceStore(paths: paths).progress(
                            "network_check", title: title, detail: detail, now: now())
                    })
            }
        self.now = now
        self.sleep = sleep
        self.discover = discover ?? { await CaptivePortalDiscovery.discover(gatewayIP: $0) }
        self.forensics =
            forensics ?? { network, client, url, reason in
                guard
                    let fingerprint = NetworkIdentity.fingerprint(network, portalDomain: url?.host)
                else { return nil }
                let recorder = ForensicRecorder(paths: paths)
                guard recorder.shouldRun(fingerprint: fingerprint, now: now()) else { return nil }
                return await recorder.run(
                    network: network, client: client, portalURL: url, reason: reason, now: now())
            }
        self.reassociate = reassociate ?? { await NativeNetworkRecovery().reassociate($0) }
        evidence = EvidenceStore(paths: paths, resources: resources)
        handoffs = BrowserHandoffStore(paths: paths)
    }

    /// Cross-process exclusion also covers the retries. A pending browser owns
    /// the next action, so launchd never repeats its static submission.
    public func once(retry: Bool = true) async -> Int32 {
        guard let lock = EngineLock.acquire(paths.lock) else { return 0 }
        defer { withExtendedLifetime(lock) {} }
        let deadline = now() + 30
        do {
            var result = try await cycle()
            while retry && result == 0 && EngineState.load(paths).result == "CAPTIVE"
                && now() + 6 < deadline
                && !FileManager.default.fileExists(atPath: paths.handoff.path) && !Task.isCancelled
            {
                try await sleep(6)
                result = try await cycle()
            }
            return result
        } catch is CancellationError { return 0 } catch {
            evidence.log(
                "native engine failed: \(String(describing: type(of: error)))", level: "ERROR",
                now: now())
            return 1
        }
    }

    private func cycle() async throws -> Int32 {
        try Task.checkCancellation()
        let identity = try PortalIdentity.load(from: paths.identity)
        let network = await inspector.current()
        var state = EngineState.load(paths)
        let previous = state.result
        let started = now()
        let changed = state.begin(network: network, now: started)
        if changed {
            handoffs.clear()
            evidence.log("network fingerprint changed; clearing venue state", now: started)
        }
        try state.save(paths)
        let ignored = (try? String(contentsOf: paths.ignored, encoding: .utf8)) ?? ""
        if let reason = NetworkIdentity.dormancy(
            network: network, identity: identity, ignoreText: ignored)
        {
            state.result = "IGNORED"
            state.fields.removeValue(forKey: "network_diagnostic")
            try state.save(paths)
            evidence.log("dormant, no probe sent: \(reason)", level: "DEBUG", now: started)
            return 0
        }
        if changed || previous != "ONLINE" {
            evidence.progress(
                "network_check", title: "Checking internet access", newAttempt: true, now: started)
        }
        let client = clientFactory(network)
        var probe = await ConnectivityProbe(client: client).check(captiveHint: network.captiveHint)
        let attemptID = UUID().uuidString
        if probe.state == .noNetwork {
            let diagnosis = await diagnose(client, network, probe.errors)
            guard await unchanged(network) else { return try networkChanged(&state) }
            let fingerprint =
                "\(network.interface ?? ""):\(network.gatewayMAC ?? network.gatewayIP ?? ""):\(network.ssid ?? "")"
            let report = NetworkDiagnostics.record(
                diagnosis, previous: state.fields["network_diagnostic"] as? [String: Any] ?? [:],
                fingerprint: fingerprint, now: now())
            if let url = diagnosis.portalURL {
                probe = ProbeResult(
                    state: .captive, redirectURL: url, source: "dns-independent-discovery",
                    errors: probe.errors)
            } else {
                state.result = "NO_NETWORK"
                state.failures = 0
                state.fields["network_diagnostic"] = report
                PrivateFile.remove(paths.handoff)
                evidence.progress(
                    "network_unavailable",
                    title: report["title"] as? String ?? "Wi-Fi access unavailable",
                    detail: report["detail"] as? String, reason: report["reason"] as? String,
                    now: now())
                evidence.trace(
                    attempt: attemptID, phase: "outcome",
                    title: report["title"] as? String ?? "Network unavailable",
                    detail: report["checks"] as? String ?? "", status: "stopped", now: now())
                try state.save(paths)
                return 0
            }
        }
        guard await unchanged(network) else { return try networkChanged(&state) }
        state.fields.removeValue(forKey: "network_diagnostic")
        if probe.state == .online {
            state.markOnline(
                network: network, now: now(), automatedLogin: false, newConnection: changed)
            handoffs.clear()
            evidence.confirmAccess(now: now())
            if previous != "ONLINE" || changed {
                evidence.trace(
                    attempt: attemptID, phase: "probe", title: "Internet access confirmed",
                    detail: "Connectivity check passed; no portal submission was needed.",
                    now: now())
            }
            if !changed && ["CAPTIVE", "UNSUPPORTED"].contains(previous) {
                evidence.log(
                    "activity notification: Cuppa Wi-Fi — back online", level: "DEBUG", now: now())
            }
            try state.save(paths)
            return 0
        }

        var portalURL = probe.redirectURL
        if portalURL == nil, let url = NativeNetworkRecovery.gatewayURL(network.gatewayIP) {
            if let response = try? await client.send(HTTPRequest(url: url, timeout: 3)) {
                portalURL =
                    response.header("location").flatMap {
                        PortalRequestURL.url($0, relativeTo: response.url)?.absoluteURL
                    } ?? response.url
            }
        }
        if portalURL == nil { portalURL = await discover(network.gatewayIP) }
        let url = portalURL ?? ConnectivityProbe.appleURL
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            return 1
        }
        guard await unchanged(network) else { return try networkChanged(&state) }
        let domain = url.host
        let fingerprint = NetworkIdentity.fingerprint(network, portalDomain: domain)
        state.fields["portal_domain"] = domain
        if let ssid = network.ssid { state.fields["ssid"] = ssid }
        if handoffs.active(fingerprint: fingerprint, now: now()) {
            state.result = "CAPTIVE"
            try state.save(paths)
            return 0
        }
        if let reason = handoffs.unsupported(fingerprint: fingerprint, now: now()),
            Self.unsupportedReasons.contains(reason)
        {
            state.result = "UNSUPPORTED"
            state.failures = 0
            evidence.progress(
                "stopped",
                title: reason == "portal_page_unavailable"
                    ? "Wi-Fi sign-in page unavailable" : "Sign-in needs attention",
                detail: reason == "portal_page_unavailable"
                    ? "Ask the venue whether its Wi-Fi sign-in service is available." : nil,
                reason: reason,
                now: now())
            try state.save(paths)
            return 0
        }
        let firstVisit = !evidence.seenVenue(fingerprint)
        evidence.progress(
            "detected", title: "Captive portal detected", newAttempt: true, now: now())
        evidence.log(
            "captive portal detected: venue=\(state.fields["venue"] as? String ?? domain ?? "network") portal_domain=\(domain ?? "unknown")",
            now: now())
        if !["CAPTIVE", "UNSUPPORTED"].contains(state.result) {
            evidence.log(
                "activity notification: Cuppa Wi-Fi — portal detected, signing in…", level: "DEBUG",
                now: now())
            state.fields["last_notified_event"] = "captive_detected"
        }
        evidence.trace(
            attempt: attemptID, phase: "portal", title: "Captive portal detected",
            detail: domain ?? "Host unavailable", now: now())
        evidence.progress(
            "static_form", title: "Reading and submitting the portal form", now: now())
        var attempt = await portalFactory(client).login(
            url: url, identity: identity, network: network)
        try Task.checkCancellation()
        guard await unchanged(network) else { return try networkChanged(&state) }
        for step in attempt.steps.prefix(64) {
            evidence.trace(
                attempt: attemptID, phase: step.phase, title: step.title, detail: step.detail,
                status: step.status, fields: step.fields, now: now())
        }
        if attempt.steps.contains(where: {
            $0.phase == "validation" && $0.fields.contains(where: { $0.intent == "phone" })
        }), let fingerprint {
            rememberPhoneRejection(fingerprint)
        }
        if let venue = attempt.venue {
            state.fields["venue"] = venue
            evidence.log("portal venue identified: \(venue)", now: now())
        }
        evidence.progress(
            "verification", title: "Verifying internet access", actions: attempt.actions, now: now()
        )
        // Fresh client prevents portal cookies from affecting the independent probes.
        var verification = await ConnectivityProbe(client: clientFactory(network)).check(
            requireConsensus: true)
        guard await unchanged(network) else { return try networkChanged(&state) }
        let acceptedAction = attempt.actions > 0 || attempt.pendingSubmission
        // Controllers may accept the form before their access rule propagates.
        // Re-observe access without submitting again, within this attempt's budget.
        if attempt.outcome == .submitted && acceptedAction && verification.state != .online {
            for _ in 1..<6 {
                guard now() + 2 < started + 30 else { break }
                try await sleep(2)
                guard await unchanged(network) else { return try networkChanged(&state) }
                verification = await ConnectivityProbe(client: clientFactory(network)).check(
                    requireConsensus: true)
                guard await unchanged(network) else { return try networkChanged(&state) }
                if verification.state == .online { break }
            }
        }
        // A controller can accept the request but serve a broken decorative landing
        // page after granting access. An actual HTTP error is not acceptance.
        let acceptedSoftError =
            attempt.outcome == .unsupported
            && attempt.reason == "portal_page_unavailable"
            && attempt.hops.last?.response.map { (200..<400).contains($0.status) } == true
        let success =
            (attempt.outcome == .submitted || acceptedSoftError)
            && acceptedAction && verification.state == .online
        evidence.trace(
            attempt: attemptID, phase: "probe", title: "Probe: \(verification.state.rawValue)",
            detail: success ? "Internet access verified" : attempt.reason,
            status: success ? "ok" : "fail", now: now())
        if !acceptedAction && verification.state == .online
            && (attempt.outcome == .submitted
                || (attempt.outcome == .browser
                    && ["no_static_form_found", "no_supported_form_found"].contains(attempt.reason)))
        {
            // Access may have been granted externally. Preserve connectivity truth
            // without crediting an automatic login or learning an unexecuted strategy.
            state.markOnline(network: network, now: now(), automatedLogin: false)
            handoffs.clear()
            evidence.progress(
                "connected", title: "Internet access confirmed",
                detail: "No automatic portal action was required.", now: now())
            try state.save(paths)
            return 0
        }
        if success {
            state.markOnline(network: network, now: now(), automatedLogin: true)
            evidence.progress(
                "connected", title: "Internet access confirmed", actions: attempt.actions,
                now: now())
            evidence.staticOutcome(
                host: domain ?? "", provider: attempt.provider, fingerprint: fingerprint,
                outcome: "verified", firstVisit: firstVisit, now: now())
            evidence.remember(
                url: url, signature: attempt.signature, execution: "static",
                provider: attempt.provider, now: now())
            if let fingerprint, !evidence.hasCapture(fingerprint, successful: true) {
                evidence.capture(attempt, fingerprint: fingerprint, successful: true, now: now())
            }
            handoffs.clear()
            evidence.log(
                "auto-login succeeded: venue=\(state.fields["venue"] as? String ?? "network") source=\(verification.source)",
                now: now())
            evidence.log(
                "activity notification: Cuppa Wi-Fi — back online", level: "DEBUG", now: now())
            try state.save(paths)
            return 0
        }
        if attempt.outcome == .submitted {
            attempt.outcome = .browser
            attempt.reason =
                attempt.actions == 0
                ? "no_supported_form_found" : "submission_accepted_but_portal_remains"
        }
        let key = fingerprint ?? "unknown"
        if attempt.reason == "persona_phone_rejected" { rememberPhoneRejection(key) }
        if attempt.outcome == .unsupported {
            if state.fields["last_notified_event"] as? String != "unsupported:\(key)" {
                evidence.log(
                    "activity notification: Cuppa Wi-Fi — needs verification", level: "DEBUG",
                    now: now())
            }
            state.result = "UNSUPPORTED"
            state.failures = 0
            state.fields["last_notified_event"] = "unsupported:\(key)"
            let capture =
                evidence.hasCapture(key)
                ? nil : evidence.capture(attempt, fingerprint: key, successful: false, now: now())
            try handoffs.stop(reason: attempt.reason, fingerprint: fingerprint, now: now())
            try handoffs.write(
                attempt: attempt, network: network, fingerprint: fingerprint,
                cookies: await client.cookies(), capturedPath: capture, firstVisit: firstVisit,
                now: now())
            evidence.staticOutcome(
                host: domain ?? "", provider: attempt.provider, fingerprint: fingerprint,
                outcome: "unsupported", firstVisit: firstVisit, now: now())
            evidence.progress(
                "stopped",
                title: attempt.reason == "portal_page_unavailable"
                    ? "Wi-Fi sign-in page unavailable" : "Sign-in needs attention",
                detail: attempt.reason == "portal_page_unavailable"
                    ? "Ask the venue whether its Wi-Fi sign-in service is available." : nil,
                reason: attempt.reason, actions: attempt.actions, now: now())
        } else {
            state.result = "CAPTIVE"
            state.failures += 1
            let capture = evidence.capture(attempt, fingerprint: key, successful: false, now: now())
            if attempt.outcome == .browser
                || BrowserHandoffStore.browserReasons.contains(attempt.reason)
            {
                try handoffs.write(
                    attempt: attempt, network: network, fingerprint: fingerprint,
                    cookies: await client.cookies(), capturedPath: capture, firstVisit: firstVisit,
                    now: now())
                evidence.progress(
                    "browser_handoff", title: "Preparing the browser for the next step",
                    reason: attempt.reason, actions: attempt.actions, now: now())
            } else {
                evidence.staticOutcome(
                    host: domain ?? "", provider: attempt.provider, fingerprint: fingerprint,
                    outcome: "failed", firstVisit: firstVisit, now: now())
                evidence.progress(
                    "stopped", title: "Sign-in stopped — needs attention", reason: attempt.reason,
                    actions: attempt.actions, now: now())
                let transient = [
                    "portal_dns_unavailable", "portal_transport_unavailable",
                    "portal_attempt_deadline_exceeded",
                ].contains(attempt.reason)
                if !transient || state.failures >= 2 {
                    if let sweep = await forensics(
                        network, clientFactory(network), url, attempt.reason),
                        let summary = PrivateFile.object(
                            at: sweep.appendingPathComponent("summary.json"))
                    {
                        let analysis = summary["portal_final_analysis"] as? [String: Any]
                        let target =
                            summary["cna_portal_url"] as? String
                            ?? (analysis?["looks_js_rendered"] as? Bool == true
                                ? summary["portal_final_url"] as? String : nil)
                        if let target, let recovered = PortalRequestURL.url(target),
                            ["http", "https"].contains(recovered.scheme ?? ""),
                            recovered.host != nil
                        {
                            var recoveredAttempt = attempt
                            recoveredAttempt.portalURL = recovered
                            recoveredAttempt.outcome = .browser
                            recoveredAttempt.reason = "requires_browser"
                            try handoffs.write(
                                attempt: recoveredAttempt, network: network,
                                fingerprint: fingerprint, cookies: await client.cookies(),
                                capturedPath: sweep, firstVisit: firstVisit, now: now())
                        }
                    }
                    guard await unchanged(network) else { return try networkChanged(&state) }
                }
                if state.failures == 2, identity.enableReassociation,
                    let interface = network.interface,
                    now() - (state.fields["last_reassoc_ts"] as? Double ?? -.infinity) > 600
                {
                    await reassociate(interface)
                    state.fields["last_reassoc_ts"] = now()
                }
            }
            evidence.log(
                "login failed (\(state.failures) consecutive, reason=\(EvidenceStore.safeReason(attempt.reason) ?? "unknown"))",
                level: "WARNING", now: now())
            if state.failures >= 4 && state.fields["last_notified_event"] as? String != "give_up" {
                evidence.log(
                    "activity notification: Cuppa Wi-Fi — can't auto-login; portal captured",
                    level: "DEBUG", now: now())
                state.fields["last_notified_event"] = "give_up"
            }
        }
        try state.save(paths)
        return 0
    }

    public func completeBrowser(
        fingerprint: String? = nil, venue: String? = nil, report: URL? = nil, assisted: Bool = false
    ) async -> Int32 {
        guard let lock = EngineLock.acquire(paths.lock) else { return 3 }
        defer { withExtendedLifetime(lock) {} }
        var state = EngineState.load(paths)
        if let fingerprint, fingerprint != state.fingerprint { return 4 }
        let pending = evidence.report(at: report)
        let assisted = assisted || pending?["source"] as? String == "assisted"
        let network = await inspector.current()
        if let expected = state.network.gatewayMAC, expected != network.gatewayMAC { return 4 }
        if NetworkIdentity.changed(from: state.network, to: network) { return 4 }
        var result = await ConnectivityProbe(client: clientFactory(network)).check(
            requireConsensus: true)
        if result.state != .online && report != nil {
            for delay in [0.5, 1.0] {
                do { try await sleep(delay) } catch { return 2 }
                guard await unchanged(network) else { return 4 }
                result = await ConnectivityProbe(client: clientFactory(network)).check(
                    requireConsensus: true)
                if result.state == .online { break }
            }
        }
        guard await unchanged(network) else { return 4 }
        guard result.state == .online else {
            _ = evidence.outcome(report: report, verified: false, assisted: assisted, now: now())
            try? handoffs.stop(
                reason: "connectivity_unverified", fingerprint: state.fingerprint, now: now())
            state.result = "CAPTIVE"
            state.failures = 0
            try? state.save(paths)
            return 2
        }
        if let venue {
            let clean = venue.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !clean.isEmpty && clean.count <= 80
                && clean.unicodeScalars.allSatisfy({ $0.value >= 32 })
            {
                state.fields["venue"] = clean
            }
        }
        state.markOnline(
            network: network, now: now(), automatedLogin: !assisted, newConnection: true)
        do { try state.save(paths) } catch { return 1 }
        let savedReport = evidence.outcome(
            report: report, verified: true, assisted: assisted, now: now())
        if let savedReport, savedReport["source"] as? String == "automatic",
            let signature = savedReport["signature"] as? String,
            let handoff = PrivateFile.object(at: paths.handoff),
            handoff["signature"] as? String == signature,
            let urlText = handoff["portal_url"] as? String, let url = PortalRequestURL.url(urlText),
            url.host == savedReport["host"] as? String
        {
            evidence.remember(
                url: url, signature: signature, execution: "browser",
                provider: savedReport["provider"] as? String ?? "generic", now: now())
        }
        handoffs.clear()
        evidence.progress("connected", title: "Internet access confirmed", now: now())
        evidence.log(
            "webview \(assisted ? "assisted sign-in" : "auto-login") succeeded: source=\(result.source)",
            now: now())
        return 0
    }

    public func markUnsupported(reason: String, fingerprint: String?, report: URL? = nil) async
        -> Int32
    {
        guard Self.unsupportedReasons.contains(reason), let fingerprint else { return 2 }
        guard let lock = EngineLock.acquire(paths.lock) else { return 3 }
        defer { withExtendedLifetime(lock) {} }
        var state = EngineState.load(paths)
        guard state.fingerprint == fingerprint else { return 4 }
        let network = await inspector.current()
        guard !NetworkIdentity.changed(from: state.network, to: network),
            state.network.gatewayMAC == nil || state.network.gatewayMAC == network.gatewayMAC
        else { return 4 }
        _ = evidence.outcome(report: report, now: now())
        do {
            try handoffs.stop(reason: reason, fingerprint: fingerprint, now: now())
            PrivateFile.remove(paths.handoff)
            state.result = "UNSUPPORTED"
            state.failures = 0
            state.fields["last_notified_event"] = "unsupported:\(fingerprint)"
            try state.save(paths)
            evidence.progress(
                "stopped", title: "Sign-in needs attention", reason: reason, now: now())
            return 0
        } catch { return 1 }
    }

    private func unchanged(_ network: NetworkSnapshot) async -> Bool {
        NetworkIdentity.sameConnection(network, await inspector.current())
    }
    private func networkChanged(_ state: inout EngineState) throws -> Int32 {
        state.fields.removeValue(forKey: "network_diagnostic")
        state.result = "UNKNOWN"
        handoffs.clear()
        try state.save(paths)
        evidence.progress(
            "network_unavailable", title: "Wi-Fi changed during the check",
            detail:
                "Discarded the old network result. Checking the new connection on the next monitoring cycle.",
            reason: "network_changed", now: now())
        return 0
    }
    private func rememberPhoneRejection(_ key: String) {
        PhonePolicyStore(path: paths.root.appendingPathComponent("phone_policy.json")).remember(key)
    }
}

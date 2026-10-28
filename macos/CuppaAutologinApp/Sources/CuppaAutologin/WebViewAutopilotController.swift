import AppKit
import Foundation
import WebKit
import OSLog

@MainActor
final class WebViewAutopilotController: NSObject, WKNavigationDelegate, WKScriptMessageHandler, NSWindowDelegate {
    static let autofillWorld = WKContentWorld.world(name: "CuppaAutofill")
    // WKFrameInfo identifies a frame, not its current document. Navigation can
    // replace that document between native authorization and script execution.
    // Check in the same isolated-world call before giving the executor secrets.
    static let guardedAutofillScript = """
        if (expectedFrameURL && globalThis.origin !== new URL(expectedFrameURL).origin) {
          return {status: 'no_form', detail: 'frame_origin_changed', journey: journey, trace: journey.trace};
        }
        return await window.__wifiAutologinAutofill.run({
          identity: identity, credentials: credentials, corrections: corrections, schema: schema, profiles: profiles,
          readinessTimeoutMs: 6000, transitionTimeoutMs: 2500, maxSteps: maximumActions,
          correctionLadder: correctionLadder, journey: journey,
          deadline: deadline, startedAt: startedAt
        });
        """

    enum Outcome {
        case submitted(String?)
        case unsupported(String)
        case failed(String)
    }

    private let portalURL: URL
    private let identity: FakeIdentity
    let diagnosticAttempt = "webview-" + UUID().uuidString
    private let networkSSID: String?
    private let diagnosticLogURL: URL
    private let script: String
    private let schema: [String: Any]
    private let profiles: [String: Any]
    private let correctionLadder: [String: Any]
    private let handoff: WebViewHandoffRecord?
    private let completion: @MainActor (Outcome) -> Void
    private let progress: (@MainActor (PortalDiagnostics) -> Void)?
    private let logger = Logger(subsystem: "io.github.tommyyau.wifi-autologin", category: "portal")
    private var diagnostics = PortalDiagnostics(startedAt: Date().timeIntervalSince1970,
        updatedAt: Date().timeIntervalSince1970, phase: "browser_load", title: "Loading the portal in the browser")
    private var failureReason: String?
    private var provisionalRetries = 0
    private var navigationRetryTask: Task<Void, Never>?
    private var engineLock: SharedEngineLock?
    private(set) var webView: WKWebView?
    private var timeoutTask: Task<Void, Never>?
    private var evaluationInFlight = false
    private var mainDocumentReady = false
    private var waitingForLoadedDocument = false
    private let reasoner: (any LocalPortalReasoning)?
    private var reasoningTask: Task<Void, Never>?
    private var reasoningTimeoutTask: Task<Void, Never>?
    private var reasoningRequestID: String?
    private var reasoningRequests = 0
    private var maximumReasoningRequests: Int {
        min(12, max(0, (schema["reasoning"] as? [String: Any])?["maxRequests"] as? Int ?? 12))
    }
    private var reasoningDecisions = 0
    private var finished = false
    private var navigationCount = 0
    private var journey = PortalJourney()
    private var evaluationID = UUID()
    private let credentials: PortalCredentials?
    private let accountScope: String?
    private let accountStore: PortalAccountStore
    private var submittedAccount: PortalCredentials?
    private var existingAccountOrigin: String?
    private var reportedAccountOrigins: Set<String> = []
    private let browserResolver: PortalBrowserTransport.Resolver?
    private var browserTransport: PortalBrowserTransport?
    private var browserStartTask: Task<Void, Never>?
    private var signupOrigin: String?
    private var failureNetworkPath: String?
    private var corrections: [String: [String: [String]]] = [:]

    private func origin(of url: URL) -> String {
        "\(url.scheme ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }
    private func portalURL(for frame: WKFrameInfo) -> URL? {
        let securityOrigin = frame.securityOrigin
        return PortalFrameURL.make(scheme: securityOrigin.protocol, host: securityOrigin.host,
                                   port: securityOrigin.port, requestURL: frame.request.url,
                                   mainURL: webView?.url ?? portalURL)
    }

    private var lastResult: WebViewAutopilotResult?
    private var frameCandidates: [WKFrameInfo] = []
    private var deadline: Date
    private let startedAt = Date()
    private var manualWindow: NSWindow?
    private(set) var assisted = false
    private(set) var diagnosticsURL: URL?

    init?(portalURL: URL, identity: FakeIdentity, scriptURL: URL,
          correctionLadderURL: URL, engineLock: SharedEngineLock,
          handoff: WebViewHandoffRecord? = nil, diagnosticsDirectory: URL? = nil,
          diagnosticLogURL: URL = SystemPaths.logFile,
          reasoner: (any LocalPortalReasoning)? = nil, useLocalReasoning: Bool = true,
          credentials: PortalCredentials? = nil,
          accountScope: String? = nil, accountStore: PortalAccountStore = .shared,
          browserResolver: PortalBrowserTransport.Resolver? = nil,
          progress: (@MainActor (PortalDiagnostics) -> Void)? = nil,
          networkSSID: String? = nil,
          completion: @escaping @MainActor (Outcome) -> Void) {
        let resources = correctionLadderURL.deletingLastPathComponent()
        func json(_ url: URL) -> [String: Any]? {
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              let ladder = json(correctionLadderURL),
              let schema = json(resources.appendingPathComponent("portal-schema.json")),
              let profiles = json(resources.appendingPathComponent("vendor-profiles.json")) else {
            engineLock.release()
            return nil
        }
        self.portalURL = portalURL
        self.identity = identity
        self.networkSSID = networkSSID
        self.diagnosticLogURL = diagnosticLogURL
        self.script = script
        self.schema = schema
        self.profiles = profiles
        self.correctionLadder = ladder
        self.engineLock = engineLock
        self.handoff = handoff
        self.credentials = credentials?.authorizes(portalURL) == true ? credentials : nil
        self.accountScope = accountScope
        self.accountStore = accountStore
        self.browserResolver = browserResolver
        self.journey.pendingSubmission = handoff?.pendingSubmission
        self.reasoner = reasoner ?? (useLocalReasoning ? LocalPortalReasoner.makeAvailable() : nil)
        self.deadline = min(Date().addingTimeInterval(90), Date(timeIntervalSince1970: handoff?.deadline ?? Date().addingTimeInterval(90).timeIntervalSince1970))
        self.diagnosticsURL = diagnosticsDirectory?.appendingPathComponent(UUID().uuidString + ".json")
        self.completion = completion
        self.progress = progress
        super.init()
        if let saved = handoff?.corrections { corrections[origin(of: portalURL)] = saved }
    }

    func start() {
        trace("network", "Connected to Wi-Fi", "SSID: " + (networkSSID ?? "unavailable"))
        trace("portal", "Captive portal detected", portalURL.host ?? "Host unavailable")
        if progress != nil, let previous = PortalDiagnostics.load(from: SystemPaths.portalProgress),
           previous.isActive(at: Date()) { diagnostics = previous }
        publishProgress("browser_load", "Loading the portal in the browser")
        armTimeout()
        browserStartTask = Task { [weak self] in
            guard let self else { return }
            if let interface = self.handoff?.networkInterface, #available(macOS 14.0, *) {
                let transport = PortalBrowserTransport()
                self.browserTransport = transport
                do {
                    try await transport.start(interface: interface, portalURL: self.portalURL,
                                              gatewayIP: self.handoff?.networkGatewayIP, resolver: self.browserResolver)
                    guard !self.finished, !Task.isCancelled else { transport.stop(); return }
                    self.publishProgress("browser_transport", "Loading the portal through Wi-Fi")
                } catch {
                    transport.stop()
                    self.failureReason = "browser_transport_unavailable"
                    self.finish(.failed("The browser could not start its Wi-Fi transport"))
                    return
                }
            }
            guard !self.finished, !Task.isCancelled else { return }
            self.startBrowser()
        }
    }

    private func startBrowser() {
        let configuration = WKWebViewConfiguration()
        if let transport = browserTransport, #available(macOS 14.0, *) {
            configuration.websiteDataStore = .nonPersistent()
            transport.configure(configuration.websiteDataStore)
        } else {
            configuration.websiteDataStore = .default()
        }
        let userContent = configuration.userContentController
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalJourney")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalFrame")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalManualStage")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalReasoning")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalAccount")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "portalCorrections")
        userContent.add(WeakPortalMessageHandler(self), contentWorld: Self.autofillWorld, name: "diagnosticStep")
        let schemaJSON = String(data: try! JSONSerialization.data(withJSONObject: schema), encoding: .utf8)!
        let profilesJSON = String(data: try! JSONSerialization.data(withJSONObject: profiles), encoding: .utf8)!
        let manualObserver = """
        (function(){
          var timer;
          function capture(event){
            try {
              var api=window.__wifiAutologinAutofill, stage=api.stageSnapshot(document);
              var target=event && event.target && event.target.closest && event.target.closest('button,a,[role="button"],input[type="submit"]');
              var data={signature:stage.signature,stage:stage.kind,fields:stage.fields,
                action:target ? api.signatureHash(target.tagName+' '+(target.textContent||target.value||'')) : '00000000',
                elapsed_ms:0,outcome:'pending'};
              window.webkit.messageHandlers.portalManualStage.postMessage(data);
            } catch (_) {}
          }
          document.addEventListener('click',capture,true);
          new MutationObserver(function(){clearTimeout(timer);timer=setTimeout(capture,200)}).observe(document.documentElement,{childList:true,subtree:true,attributes:true});
        })();
        """
        let reasoningBridge = """
        window.__wifiAutologinReasoningEnabled = \(self.reasoner != nil);
        (function(){
          var pending={},sequence=0;
          window.__wifiAutologinResolveReasoning=function(id,result){
            var callback=pending[id]; if(callback){delete pending[id];callback(result);}
          };
          window.__wifiAutologinReason=function(request){
            if(!window.__wifiAutologinReasoningEnabled)return Promise.resolve(null);
            request.id='r'+Date.now().toString(36)+'-'+(++sequence);
            return new Promise(function(resolve){
              var timer=setTimeout(function(){delete pending[request.id];resolve(null)},5200);
              pending[request.id]=function(result){clearTimeout(timer);resolve(result)};
              try{window.webkit.messageHandlers.portalReasoning.postMessage(request)}
              catch(_){window.__wifiAutologinResolveReasoning(request.id,null)}
            });
          };
        })();
        """
        let injected = "window.__wifiAutologinSchema = " + schemaJSON
            + "; window.__wifiAutologinProfiles = " + profilesJSON + ";\n" + script
            + "\n" + reasoningBridge
            + "\ntry { window.webkit.messageHandlers.portalFrame.postMessage({ready: true}); } catch (_) {}" + manualObserver
        userContent.addUserScript(WKUserScript(source: injected, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Self.autofillWorld))
        let view = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        view.navigationDelegate = self
        self.webView = view
        armTimeout()
        Task { [weak self] in
            guard let self else { return }
            for cookie in self.handoff?.cookies ?? [] {
                guard !cookie.name.isEmpty, cookie.value.count < 8192,
                      cookie.expires == nil || cookie.expires! > Date().timeIntervalSince1970 else { continue }
                var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value,
                    .domain: cookie.domain, .path: cookie.path.isEmpty ? "/" : cookie.path]
                if cookie.secure { properties[.secure] = "TRUE" }
                if let expires = cookie.expires { properties[.expires] = Date(timeIntervalSince1970: expires) }
                if let value = HTTPCookie(properties: properties) {
                    await view.configuration.websiteDataStore.httpCookieStore.setCookie(value)
                }
            }
            guard !self.finished else { return }
            // A captive link can deliver its first document slowly. The
            // controller's shared deadline bounds the entire journey.
            var request = URLRequest(url: self.portalURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: max(1, self.deadline.timeIntervalSinceNow))
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.4 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
            view.load(request)
        }
    }

    private func armTimeout() {
        timeoutTask?.cancel()
        let remaining = max(0, deadline.timeIntervalSinceNow)
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if !self.assisted, self.journey.pendingSubmission == true {
                self.finish(.submitted(self.lastResult?.venue)) // Verify even if WebKit lost the old promise.
            } else {
                self.finish(.failed("Portal attempt timed out"))
            }
        }
    }

    func cancel() { finish(.failed("Portal attempt cancelled")) }

    func discard() {
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        cancelReasoning()
        browserStartTask?.cancel(); browserStartTask = nil
        browserTransport?.stop(); browserTransport = nil
        engineLock?.release()
        engineLock = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalJourney", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalFrame", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalManualStage", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalReasoning", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalAccount", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "portalCorrections", contentWorld: Self.autofillWorld)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "diagnosticStep", contentWorld: Self.autofillWorld)
        webView = nil
        manualWindow?.delegate = nil
        manualWindow?.close()
        manualWindow = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !finished, message.world == Self.autofillWorld else { return }
        if message.name == "diagnosticStep" {
            guard let raw = message.body as? [String: Any],
                  JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw), data.count <= 32_000,
                  let payload = try? JSONDecoder().decode(RenderedDiagnosticPayload.self, from: data)
            else { return }
            trace(payload.phase, payload.title, payload.detail, payload.status, fields: payload.fields)
            return
        }
        if message.name == "portalReasoning" {
            handleReasoning(message)
        } else if message.name == "portalAccount",
                  let body = message.body as? [String: String],
                  let url = portalURL(for: message.frameInfo), let currentURL = webView?.url,
                  ["http", "https"].contains(url.scheme ?? ""), (origin(of: url) == origin(of: currentURL) || origin(of: url) == signupOrigin
                    || credentials?.authorizes(url) == true) {
            if body["operation"] == "signup_submitted",
               credentials == nil || (credentials?.operation == .create && credentials?.authorizes(url) == true) {
                signupOrigin = origin(of: url)
                submittedAccount = credentials ?? PortalCredentials(origin: origin(of: url), operation: .create,
                    username: identity.email, password: identity.password)
            } else if body["operation"] == "existing_account", signupOrigin == origin(of: url) {
                existingAccountOrigin = origin(of: url)
            }
        } else if message.name == "portalCorrections", let values = message.body as? [String: [String]], values.count <= 30,
                  values.allSatisfy({ $0.key.count <= 240 && $0.key.range(of: "^(phone|postcode|dob):", options: .regularExpression) != nil && $0.value.count <= 4 && $0.value.allSatisfy({ $0.count <= 80 }) }),
                  let url = portalURL(for: message.frameInfo) {
            corrections[origin(of: url)] = values
        } else if message.name == "portalJourney", let value = PortalJourney.decode(message.body) {
            journey = value
            publishProgress("form_action", "Form step \(value.actions): \(value.trace.last?.outcome == "corrected" ? "trying a validation correction" : "waiting for the portal response")")
        } else if message.name == "portalManualStage", assisted,
                  let raw = message.body as? [String: Any], JSONSerialization.isValidJSONObject(raw),
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  var trace = try? JSONDecoder().decode(PortalStageTrace.self, from: data), trace.isValid {
            trace.elapsed_ms = Int(max(0, Date().timeIntervalSince(startedAt) * 1000))
            if journey.trace.count < 64 && (trace.action != "00000000" || journey.trace.last?.signature != trace.signature) {
                journey.trace.append(trace)
                if trace.action != "00000000" { journey.actions = min(32, journey.actions + 1) }
            }
        } else if message.name == "portalFrame", message.frameInfo.isMainFrame, let webView {
            // atDocumentEnd is ready for form inspection. Waiting for
            // didFinish also waits for every image/frame on a captive link.
            inspectMainDocument(in: webView)
        } else if message.name == "portalFrame", !message.frameInfo.isMainFrame, frameCandidates.count < 12 {
            frameCandidates.append(message.frameInfo)
            // A subframe can replace its JS world without a main-frame
            // didFinish callback or a resolved old evaluation promise.
            if (journey.pendingSubmission == true && evaluationInFlight) || waitingForLoadedDocument, let webView {
                waitingForLoadedDocument = false
                evaluationInFlight = false
                frameCandidates.removeAll()
                runAutofill(in: webView, frame: message.frameInfo)
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !finished else { return }
        cancelReasoning()
        evaluationInFlight = false
        evaluationID = UUID()
        mainDocumentReady = false
        waitingForLoadedDocument = false
        frameCandidates = []
        publishProgress("browser_load", provisionalRetries == 0 ? "Loading the portal page" : "Retrying the portal load (\(provisionalRetries)/2)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        if !assisted, let pattern = (schema["policy"] as? [String: Any])?["socialDestination"] as? String,
           var target = navigationAction.request.url?.absoluteString {
            for _ in 0..<3 {
                if target.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    finish(.unsupported("social_login_required"))
                    return .cancel
                }
                target = target.removingPercentEncoding ?? target
            }
        }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !assisted, navigationResponse.isForMainFrame,
           let response = navigationResponse.response as? HTTPURLResponse,
           [404, 410].contains(response.statusCode) || response.statusCode >= 500 {
            diagnostics.failureCode = response.statusCode
            if journey.pendingSubmission == true {
                // A successful grant can redirect to a broken venue website.
                // Stop page automation and let the independent probes decide.
                finish(.submitted(nil))
            } else {
                finish(.unsupported("portal_page_unavailable"))
            }
            return .cancel
        }
        return .allow
    }

    private func cancelReasoning() {
        reasoningTask?.cancel(); reasoningTask = nil
        reasoningTimeoutTask?.cancel(); reasoningTimeoutTask = nil
        reasoningRequestID = nil
    }

    private func handleReasoning(_ message: WKScriptMessage) {
        guard let webView else { return }
        guard var request = PortalReasoningRequest.decode(message.body) else {
            if let body = message.body as? [String: Any], let id = body["id"] as? String,
               id.range(of: "^[a-z0-9-]{1,48}$", options: .regularExpression) != nil {
                publishProgress("form_analysis", "Model request could not be validated")
                Task { _ = try? await webView.callAsyncJavaScript("window.__wifiAutologinResolveReasoning(id, result);",
                    arguments: ["id": id, "result": [:]], in: message.frameInfo, contentWorld: Self.autofillWorld) }
            }
            return
        }
        // Metadata describes an untrusted page even though the bridge is
        // isolated. Derive account state from the frame's security origin.
        request.accountOperation = portalURL(for: message.frameInfo).flatMap {
            credentialsFor($0)["operation"] as? String
        }
        if request.mode == "action", request.accountOperation == "existing" {
            request = PortalReasoningRequest(id: request.id, mode: request.mode, signature: request.signature,
                context: request.context, fields: request.fields, choices: request.choices,
                target: "Sign in with the authorized existing account; do not register another account",
                accountOperation: "existing")
        }
        func deliver(_ result: PortalReasoningDecision?) {
            Task { _ = try? await webView.callAsyncJavaScript("window.__wifiAutologinResolveReasoning(id, result);", arguments: ["id": request.id, "result": result?.dictionary ?? [:]], in: message.frameInfo, contentWorld: Self.autofillWorld) }
        }
        guard !assisted, let reasoner, reasoningRequestID == nil,
              reasoningRequests < maximumReasoningRequests, deadline.timeIntervalSinceNow > 1 else { deliver(nil); return }
        reasoningRequests += 1
        publishProgress("reasoning", "Resolving ambiguous form controls (model pass \(reasoningRequests))")
        reasoningRequestID = request.id
        reasoningTask = Task { [weak self] in
            let decision = await reasoner.resolve(request)?.validated(for: request)
            guard let self, !Task.isCancelled, !self.finished, self.reasoningRequestID == request.id else { return }
            self.reasoningTimeoutTask?.cancel(); self.reasoningTimeoutTask = nil
            self.reasoningRequestID = nil; self.reasoningTask = nil
            if decision != nil { self.reasoningDecisions += 1 }
            self.publishProgress("form_analysis", decision == nil ? "Model pass ended without a usable decision" : "Model decision validated — checking the form")
            deliver(decision)
        }
        let responseTimeout = min(5, max(0, deadline.timeIntervalSinceNow - 0.2))
        reasoningTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(responseTimeout))
            guard let self, !Task.isCancelled, self.reasoningRequestID == request.id else { return }
            self.cancelReasoning()
            self.publishProgress("form_analysis", "Model pass timed out — continuing within the attempt limit")
            deliver(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if mainDocumentReady {
            // A document may already be executing its form while decorative
            // resources finish. Only retry if it had no usable controls yet.
            if waitingForLoadedDocument {
                waitingForLoadedDocument = false
                runAutofill(in: webView)
            }
            return
        }
        inspectMainDocument(in: webView)
    }

    private func inspectMainDocument(in webView: WKWebView) {
        guard !mainDocumentReady else { return }
        guard !finished else { return }
        mainDocumentReady = true
        navigationCount += 1
        failureReason = nil
        diagnostics.failureCode = nil
        failureNetworkPath = nil
        publishProgress("form_analysis", "Inspecting page \(navigationCount) for fields and continue buttons")
        guard navigationCount <= 12 else { finish(.failed("Portal exceeded its navigation limit")); return }
        if assisted {
            captureManualStage(in: webView)
        } else if handoff?.manualOnly == true {
            finish(.unsupported(handoff?.unsupportedReason ?? "unknown_required_field"))
        } else {
            runAutofill(in: webView)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        noteNavigationError(error)
        finish(.failed("Portal navigation failed"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        noteNavigationError(error)
        let code = (error as NSError).code
        if !assisted, PortalLoadRetryPolicy.shouldRetry(code: code, retries: provisionalRetries,
            actions: journey.actions, pendingSubmission: journey.pendingSubmission == true,
            remaining: deadline.timeIntervalSinceNow) {
            provisionalRetries += 1
            publishProgress("browser_retry", "Portal load failed (error \(code)) — retry \(provisionalRetries)/2")
            navigationRetryTask?.cancel()
            navigationRetryTask = Task { [weak self, weak webView] in
                try? await Task.sleep(for: .seconds(self?.provisionalRetries ?? 1))
                guard let self, let webView, !Task.isCancelled, !self.finished else { return }
                webView.load(URLRequest(url: self.portalURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                        timeoutInterval: max(1, self.deadline.timeIntervalSinceNow)))
            }
            return
        }
        finish(.failed("Portal could not load (error \(code)). See Activity for details."))
    }

    private func noteNavigationError(_ error: Error) {
        diagnostics.failureCode = (error as NSError).code
        failureReason = diagnostics.failureCode == NSURLErrorNotConnectedToInternet
            ? "browser_network_unavailable" : "browser_load_failed"
        var underlying = error as NSError
        for _ in 0..<4 {
            let path = String(describing: underlying.userInfo["_NSURLErrorNWPathKey"] ?? "").lowercased()
            if path.contains("no network route") { failureNetworkPath = "no_network_route" }
            if path.contains("prohibited") || path.contains("denied") { failureNetworkPath = "network_policy_denied" }
            guard let next = underlying.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            underlying = next
        }
    }

    private func credentialsFor(_ url: URL) -> [String: Any] {
        if let submittedAccount, submittedAccount.authorizes(url), existingAccountOrigin == origin(of: url) {
            var supplied = submittedAccount.javascriptDictionary
            supplied["operation"] = "existing"
            return supplied
        }
        if let credentials, credentials.authorizes(url) {
            var supplied = credentials.javascriptDictionary
            if signupOrigin == origin(of: url) { supplied["signupSubmitted"] = true }
            if credentials.operation == .create, signupOrigin == origin(of: url),
               !PortalFrameURL.isSignup(url) {
                supplied["operation"] = "existing"
            }
            return supplied
        }
        if signupOrigin == origin(of: url) {
            return ["operation": PortalFrameURL.isSignup(url) ? "create" : "existing",
                    "username": identity.email, "password": identity.password, "signupSubmitted": true]
        }
        if credentials == nil, let account = accountStore.load(for: url, scope: accountScope) {
            if reportedAccountOrigins.insert(origin(of: url)).inserted {
                trace("account", "Remembered portal account — using sign-in", "Matched this venue and portal origin")
            }
            return account.javascriptDictionary
        }
        return [:]
    }

    /// Called only after the engine independently verifies this journey on
    /// the same network. Submission or a duplicate-email response is no proof.
    func rememberVerifiedAccount() {
        guard !assisted, let submittedAccount, let accountScope else { return }
        do { try accountStore.remember(submittedAccount, scope: accountScope) }
        catch { logger.error("Could not save the verified portal account") }
    }

    private func publishProgress(_ phase: String, _ title: String, terminal: Bool = false,
                                 reason: String? = nil) {
        diagnostics.actions = journey.actions
        diagnostics.navigations = navigationCount
        diagnostics.reasoningRequests = reasoningRequests
        diagnostics.advance(phase: phase, title: title, terminal: terminal, reason: reason)
        if reason == "portal_page_unavailable" { diagnostics.detail = ActivityLog.attentionDetail(for: reason) }
        trace(phase, title, diagnostics.detail ?? reason ?? "", terminal ? "warn" : "running")
        logger.info("Portal progress: phase=\(phase, privacy: .public) actions=\(self.journey.actions) pages=\(self.navigationCount) model_passes=\(self.reasoningRequests) code=\(self.diagnostics.failureCode ?? 0)")
        progress?(diagnostics)
    }

    private func runAutofill(in webView: WKWebView, frame: WKFrameInfo? = nil) {
        guard !evaluationInFlight, !finished else { return }
        evaluationInFlight = true
        evaluationID = UUID()
        let currentEvaluation = evaluationID
        let evaluatedNavigation = navigationCount
        Task { [weak self, weak webView] in
            guard let self, let webView, !self.finished else { return }
            do {
                // An unknown subframe URL must never inherit main-frame authorization.
                let targetURL = frame == nil ? (webView.url ?? self.portalURL) : frame.flatMap { self.portalURL(for: $0) }
                let suppliedCredentials = targetURL.map { self.credentialsFor($0) } ?? [:]
                var arguments = PortalAutofillPayload.make(identity: self.identity, credentials: suppliedCredentials,
                                                          isSubframe: frame?.isMainFrame == false,
                                                          frameOrigin: targetURL.map { self.origin(of: $0) },
                                                          mainOrigin: self.origin(of: webView.url ?? self.portalURL),
                                                          // Explicit account permission never expands Persona permission.
                                                          signupOrigin: self.credentials == nil ? self.signupOrigin : nil)
                arguments.merge(["schema": self.schema, "profiles": self.profiles,
                    "expectedFrameURL": targetURL.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0.absoluteString : nil } ?? "",
                    "correctionLadder": self.correctionLadder, "journey": self.journey.dictionary,
                    "maximumActions": max(0, 8 - (self.handoff?.previousActions ?? 0)),
                    "corrections": targetURL.flatMap { self.corrections[self.origin(of: $0)] } ?? [:],
                    "deadline": self.deadline.timeIntervalSince1970 * 1000,
                    "startedAt": self.startedAt.timeIntervalSince1970 * 1000]) { _, new in new }
                let raw = try await webView.callAsyncJavaScript(Self.guardedAutofillScript, arguments: arguments,
                    in: frame, contentWorld: Self.autofillWorld)
                guard !self.finished, self.evaluationID == currentEvaluation, evaluatedNavigation == self.navigationCount else { return }
                self.evaluationInFlight = false
                guard let result = WebViewAutopilotResult.decode(raw) else {
                    self.finish(.failed("Portal returned an invalid result")); return
                }
        self.lastResult = result
                publishProgress("form_result", "Form inspection finished: \(result.status.rawValue)")
                self.journey = result.journey
                if result.status == .noForm, !self.frameCandidates.isEmpty {
                    let nextFrame = self.frameCandidates.removeFirst()
                    self.runAutofill(in: webView, frame: nextFrame)
                    return
                }
                if (result.status == .noForm || result.status == .needsMore), webView.isLoading,
                   self.journey.pendingSubmission != true {
                    // Late frames/scripts may introduce the first usable
                    // controls. Keep the same deadline and action budget.
                    self.waitingForLoadedDocument = true
                    publishProgress("browser_load", "Waiting for the portal form to become ready")
                    return
                }
                switch result.status {
                case .submitted: self.finish(.submitted(result.venue))
                case .unsupported: self.finish(.unsupported(result.detail))
                case .noForm where self.journey.pendingSubmission == true:
                    self.finish(.submitted(result.venue)) // Candidate only; the engine performs the dual probes.
                case .needsMore, .noForm: self.finish(.failed(result.detail.isEmpty ? "Portal needs attention" : result.detail))
                }
            } catch {
                guard !self.finished, self.evaluationID == currentEvaluation else { return }
                self.evaluationInFlight = false
                if webView.isLoading || self.navigationCount != evaluatedNavigation { return }
                if self.journey.pendingSubmission == true {
                    if !self.frameCandidates.isEmpty {
                        self.runAutofill(in: webView, frame: self.frameCandidates.removeFirst())
                    } else {
                        self.finish(.submitted(self.lastResult?.venue))
                    }
                    return
                }
                self.diagnostics.failureCode = (error as NSError).code
                self.failureReason = "browser_script_failed"
                self.finish(.failed("Portal script could not complete. See Activity for details."))
            }
        }
    }

    /// Reuses the failed browser and cookies; only explicit user clicks act here.
    func showAssistedSignIn(lock: SharedEngineLock) {
        guard let webView else { lock.release(); return }
        self.engineLock = lock
        self.assisted = true
        self.finished = false
        if let diagnosticsURL { self.diagnosticsURL = diagnosticsURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".json") }
        self.deadline = Date().addingTimeInterval(300)
        self.navigationCount = 0
        self.evaluationInFlight = false
        armTimeout()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 740), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Finish Wi-Fi sign-in"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "Finish the portal below, then check the connection. The app saves form structure and outcomes locally; entered details are not recorded in this report.")
        let verify = NSButton(title: "Check connection", target: self, action: #selector(verifyAssisted))
        stack.addArrangedSubview(note)
        stack.addArrangedSubview(webView)
        stack.addArrangedSubview(verify)
        stack.translatesAutoresizingMaskIntoConstraints = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            webView.widthAnchor.constraint(equalTo: stack.widthAnchor), webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 400)])
        window.contentView = content
        manualWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        captureManualStage(in: webView)
    }

    private func captureManualStage(in webView: WKWebView) {
        Task { [weak self] in
            guard let self else { return }
            if let raw = try? await webView.callAsyncJavaScript("return window.__wifiAutologinAutofill.stageSnapshot(document);", arguments: [:], in: nil, contentWorld: Self.autofillWorld),
               let value = raw as? [String: Any] {
                var event = value
                event["stage"] = event.removeValue(forKey: "kind")
                event["action"] = "00000000"
                event["elapsed_ms"] = Int(max(0, Date().timeIntervalSince(self.startedAt) * 1000))
                event["outcome"] = "pending"
                if let data = try? JSONSerialization.data(withJSONObject: event),
                   let trace = try? JSONDecoder().decode(PortalStageTrace.self, from: data), trace.isValid {
                    self.journey.trace.append(trace)
                }
            }
        }
    }

    @objc private func verifyAssisted() { finish(.submitted(nil)) }

    func windowWillClose(_ notification: Notification) {
        if !finished { cancel() }
    }

    private func saveReport(_ outcome: Outcome) {
        guard let diagnosticsURL else { return }
        let outcomeName: String
        switch outcome {
        case .submitted: outcomeName = "pending_verification"
        case .unsupported: outcomeName = "unsupported"
        case .failed: outcomeName = "failed"
        }
        var report: [String: Any] = ["format": 1, "outcome": outcomeName,
            "source": assisted ? "assisted" : "automatic", "written_at": Date().timeIntervalSince1970,
            "first_visit": handoff?.firstVisit ?? true, "execution": "browser",
            "host": portalURL.host ?? "", "provider": lastResult?.provider ?? handoff?.profileID ?? "generic",
            "navigations": navigationCount, "journey": journey.dictionary, "fieldsStillFailing": (lastResult?.fieldsStillFailing ?? []).map { ["intent": $0.intent, "type": $0.type] },
            "emailIdentityRejected": lastResult?.emailIdentityRejected ?? false,
            "local_reasoning_available": reasoner != nil, "local_reasoning_requests": reasoningRequests, "local_reasoning_decisions": reasoningDecisions]
        report["failure_reason"] = failureReason
        report["failure_code"] = diagnostics.failureCode
        report["failure_network_path"] = failureNetworkPath
        report["network_interface"] = handoff?.networkInterface
        report["browser_transport"] = browserTransport?.port == nil ? "system" : "wifi_scoped_connect"
        report["browser_proxy_connections"] = browserTransport?.connectionCount ?? 0
        if let key = handoff?.venueKey, key.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil { report["venue_key"] = key }
        if let signature = handoff?.signature { report["signature"] = signature }

        do {
            try FileManager.default.createDirectory(at: diagnosticsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: diagnosticsURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: diagnosticsURL.path)
            let reports = try FileManager.default.contentsOfDirectory(at: diagnosticsURL.deletingLastPathComponent(), includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
            for old in reports.prefix(max(0, reports.count - 200)) { try? FileManager.default.removeItem(at: old) }
        } catch { /* Diagnostics must not block connection handling. */ }
    }

    private struct RenderedDiagnosticPayload: Decodable {
        let phase: String
        let title: String
        let detail: String
        let status: String
        let fields: [DiagnosticField]
    }

    private func trace(_ phase: String, _ title: String, _ detail: String = "", _ status: String = "ok", fields: [DiagnosticField] = []) {
        DiagnosticTrace.append(DiagnosticStep(attempt: diagnosticAttempt, phase: phase, title: title,
            detail: detail, status: status, fields: fields), to: diagnosticLogURL)
    }

    private func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        navigationRetryTask?.cancel()
        navigationRetryTask = nil
        cancelReasoning()
        switch outcome {
        case .submitted: publishProgress("verification", "Portal submitted — verifying internet access")
        case let .unsupported(reason):
            failureReason = reason.range(of: "^[a-z_]{1,80}$", options: .regularExpression) == nil ? "portal_needs_attention" : reason
            publishProgress("stopped", reason == "portal_page_unavailable" ? "Wi-Fi sign-in page unavailable" : "Sign-in stopped — this portal needs your input", terminal: true, reason: failureReason)
        case let .failed(detail):
            if failureReason == nil { failureReason = detail == "Portal attempt timed out" ? "attempt_timed_out" : "portal_needs_attention" }
            publishProgress("stopped", "Sign-in stopped — needs attention", terminal: true, reason: failureReason)
        }
        saveReport(outcome)
        // Retain the browser until the independent probe verifies access, so
        // a delayed or rejected grant can still be completed in this session.
        manualWindow?.delegate = nil
        manualWindow?.orderOut(nil)
        manualWindow = nil
        engineLock?.release()
        engineLock = nil
        completion(outcome)
    }
}

private final class WeakPortalMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebViewAutopilotController?
    init(_ target: WebViewAutopilotController) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

import AppKit
import Darwin
import Foundation
import WebKit

@main
@MainActor
enum NativeWebViewSmoke {
    enum Expected {
        case submitted
        case assisted
        case failed
        case unsupported(String)
    }

    struct Scenario {
        let name: String
        let html: String
        let expected: Expected
        var useHTTP = false
        var localModel = false
        var stopBeforeAction = false
        var deterministicBypass = false
        var minimumReasoningRequests = 0
        var entryPath: String? = nil
        var scopedTransport = false
        var fixtureHost = "portal.example.test"
        var accountScope: String? = nil
        var expectedServerActions = ["signup", "login"]
        var seedAccount = false
        var expectedJourneyActions = 2
        var inspectAccountOperation = false
        var staleFrameBoundary = false
    }

    private static var controller: WebViewAutopilotController?
    private static var accountReasoner: AccountBoundaryReasoner?
    private static var staleFrameProbe: StaleFrameBoundaryProbe?
    private static var scenarioIndex = 0
    private static var completingManually = false
    private static var scriptURL: URL!
    private static var correctionLadderURL: URL!
    private static let lockDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    static let failureScript = """
    function failSmokeTest() {
      window.location.href = "http://127.0.0.1:1/wrong-form";
    }
    """

    private static var scenarios = [
        Scenario(
            name: "consent-only portal preserves hidden defaults",
            html: """
            <!doctype html><h1>Welcome to guest Wi-Fi</h1>
            <form name="merakilogin" onsubmit="finish(); return false;">
              <input type="hidden" name="email" value="guest@example.com" required>
              <input type="hidden" name="fname" value="Splash" required>
              <input type="hidden" name="baseurl" value="server-issued-grant">
              <p>By using our Wi-Fi, you agree to the terms of use.</p>
              <input name="tnc" type="checkbox" id="chkbox" style="display:none" checked required>
              <button type="submit">Accept &amp; connect</button>
            </form>
            <script>
            \(failureScript)
            function finish() {
              var form=document.forms.merakilogin;
              if(form.email.value==='guest@example.com' && form.fname.value==='Splash'
                  && form.baseurl.value==='server-issued-grant' && form.tnc.checked)
                document.body.textContent='Connected';
              else failSmokeTest();
            }
            </script>
            """,
            expected: .submitted,
            deterministicBypass: true
        ),
        Scenario(
            name: "abbreviated visible terms consent",
            html: """
            <!doctype html><form onsubmit="finish(); return false;">
              <input name="tnc" type="checkbox" required>
              <input name="tnc_marketing" type="checkbox">
              <button type="submit">Accept and continue</button>
            </form>
            <script>
            \(failureScript)
            function finish() {
              var form=document.forms[0];
              if(form.tnc.checked && !form.tnc_marketing.checked)document.body.textContent='Connected';
              else failSmokeTest();
            }
            </script>
            """,
            expected: .submitted,
            deterministicBypass: true
        ),
        Scenario(
            name: "visible form selection and privacy",
            html: """
            <!doctype html><style>.concealed { display: none }</style>
            <form class="concealed">
              <input name="first_name" required>
              <input name="last_name" required>
              <input name="email" type="email" required>
              <input name="phone" type="tel" required>
              <input name="address" required>
              <button type="button" onclick="failSmokeTest()">Connect</button>
            </form>
            <form id="active">
              <label for="email">Email address</label>
              <input id="email" type="email" required>
              <input id="hidden-trap" class="concealed" required>
              <label><input id="terms" type="checkbox" required>
                Accept terms and conditions</label>
              <label><input id="marketing" type="checkbox">
                Receive marketing offers</label>
              <button type="button" onclick="finish()">Connect</button>
            </form>
            <script>
              \(failureScript)
              function finish() {
                if (email.value === "sarah.chen.wifi@gmail.com"
                    && hiddenTrap().value === ""
                    && terms.checked
                    && !marketing.checked) {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
              function hiddenTrap() {
                return document.getElementById("hidden-trap");
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "cookie overlay rejected before portal form",
            html: """
            <!doctype html>
            <div id="cookie-overlay">
              <h1>Cookies</h1>
              <button type="button"
                onclick="failSmokeTest()">Accept all cookies</button>
              <button id="reject-cookies" type="button"
                onclick="rejectCookies()">Reject all cookies</button>
            </div>
            <form>
              <button type="button" onclick="finish()">Get online</button>
            </form>
            <script>
              \(failureScript)
              var cookiesRejected = false;
              function rejectCookies() {
                cookiesRejected = true;
                document.getElementById("cookie-overlay").style.display =
                  "none";
              }
              function finish() {
                if (cookiesRejected) {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "Costa image-link click-through",
            html: """
            <!doctype html>
            <ul><li><input id="disclosure" type="checkbox">
              \(String(repeating: "Terms of access to Costa WiFi. ", count: 40))
            </li></ul>
            <div class="cos_terms">
              <div class="box_container">
                <label class="check">
                  <input id="consent" type="checkbox">
                  <div class="expandable">
                    <a id="grant" href="#"
                      title="Continue to the Internet"
                      onclick="finish(event)"><img alt="Connect"></a>
                  </div>
                </label>
              </div>
              <div class="Checkbox-Disclaimer">
                I agree to the terms and conditions of Costa Coffee Wi-fi.
              </div>
            </div>
            <script>
              \(failureScript)
              function finish(event) {
                event.preventDefault();
                if (!consent.checked) {
                  document.body.insertAdjacentHTML(
                    "beforeend", "<p>Enter the SMS verification code (consent unchecked)</p>");
                } else if (disclosure.checked) {
                  document.body.insertAdjacentHTML(
                    "beforeend", "<p>CAPTCHA required (disclosure checked)</p>");
                } else {
                  document.body.textContent = "Connected";
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "verification surrender",
            html: """
            <!doctype html><p>Enter the SMS verification code</p>
            <form><input name="code" required>
              <button type="button" onclick="failSmokeTest()">Continue</button>
            </form>
            <script>\(failureScript)</script>
            """,
            expected: .unsupported("sms_verification")
        ),
        Scenario(
            name: "delayed SPA form",
            html: """
            <!doctype html><form id="empty-template"></form>
            <script>
              \(failureScript)
              setTimeout(function () {
                document.body.innerHTML = `
                  <form>
                    <label>Email address<input id="email" required></label>
                    <button type="button" onclick="finish()">Connect</button>
                  </form>`;
              }, 100);
              function finish() {
                if (email.value === "sarah.chen.wifi@gmail.com") {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "multi-step rendered form",
            html: """
            <!doctype html>
            <form id="step-one">
              <label>First name<input id="first" required></label>
              <label>Last name<input id="last" required></label>
              <button type="button" onclick="next()">Continue</button>
            </form>
            <script>
              \(failureScript)
              function next() {
                if (first.value !== "Sarah" || last.value !== "Chen") {
                  failSmokeTest();
                  return;
                }
                document.body.innerHTML = `
                  <form>
                    <label>Email address<input id="email" required></label>
                    <label>Postcode<input id="postcode" required></label>
                    <button type="button" onclick="finish()">Connect</button>
                  </form>`;
              }
              function finish() {
                if (email.value === "sarah.chen.wifi@gmail.com"
                    && postcode.value === "SW1A 1AA") {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "Pret-style form then standalone activation",
            html: """
            <!doctype html>
            <h1>Welcome to Pret</h1>
            <form id="details">
              <label>First name<input id="first" required></label>
              <label>Last name<input id="last" required></label>
              <button type="button" onclick="next()">Sign up</button>
            </form>
            <script>
              \(failureScript)
              function next() {
                if (first.value !== "Sarah" || last.value !== "Chen") {
                  failSmokeTest();
                  return;
                }
                document.body.innerHTML = `
                  <h1>You're nearly there</h1>
                  <button id="activate" type="button"
                    onclick="finish()">Get online</button>`;
              }
              function finish() {
                document.body.textContent = "Connected";
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "controlled input events",
            html: """
            <!doctype html><form>
              <label>Email address<input id="email" type="email" required></label>
              <button type="button" onclick="finish()">Connect</button>
            </form>
            <script>
              \(failureScript)
              var nativeValue = Object.getOwnPropertyDescriptor(
                HTMLInputElement.prototype, "value"
              );
              var tracked = "";
              var frameworkState = "";
              Object.defineProperty(email, "value", {
                configurable: true,
                get: function () { return nativeValue.get.call(email); },
                set: function (value) {
                  tracked = String(value);
                  nativeValue.set.call(email, value);
                }
              });
              email.addEventListener("input", function () {
                var current = nativeValue.get.call(email);
                if (current !== tracked) {
                  tracked = current;
                  frameworkState = current;
                }
              });
              function finish() {
                if (frameworkState === "sarah.chen.wifi@gmail.com") {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(
            name: "Pret-style sign-up wording",
            html: """
            <!doctype html><form>
              <label>First name<input id="first" required></label>
              <label>Last name<input id="last" required></label>
              <label>Email address<input id="email" type="email" required></label>
              <label><input id="terms" type="checkbox" required>
                Accept terms and conditions</label>
              <button type="button" onclick="finish()">Sign up</button>
            </form>
            <script>
              \(failureScript)
              function finish() {
                if (first.value === "Sarah"
                    && last.value === "Chen"
                    && email.value === "sarah.chen.wifi@gmail.com"
                    && terms.checked) {
                  document.body.textContent = "Connected";
                } else {
                  failSmokeTest();
                }
              }
            </script>
            """,
            expected: .submitted
        ),
        Scenario(name: "ancestor-hidden panel is ignored", html: """
          <div style="display:none"><form><input name="email" type="email" required><input name="postcode" required><button onclick="failSmokeTest()">Connect</button></form></div>
          <form><input id="email" type="email" required><button type="button" onclick="document.body.textContent = email.value === 'sarah.chen.wifi@gmail.com' ? 'Connected' : failSmokeTest()">Connect</button></form><script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "native controlled dropdown and external controls", html: """
          <form id="guest"><label>Country<select id="country" name="country" required><option value="">Choose</option><option value="GB">United Kingdom</option></select></label>
          <button type="button" onclick="finish()">Connect</button></form>
          <input id="external" type="email" autocomplete="section-guest email" required form="guest">
          <script>\(failureScript)
          var state = ''; var changed = false;
          var setter = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, 'value');
          Object.defineProperty(country, 'value', {get: function(){return setter.get.call(this)}, set:function(value){setter.set.call(this,value);state=value}});
          country.addEventListener('input', function(){state=setter.get.call(this)});
          country.addEventListener('change', function(){changed=true});
          function finish(){if(state==='GB' && changed && external.value==='sarah.chen.wifi@gmail.com') document.body.textContent='Connected';else failSmokeTest()}
          </script>
          """, expected: .submitted),
        Scenario(name: "same form and button reused with delayed readiness", html: """
          <form id="guest"><label id="label">First name</label><input id="value" aria-labelledby="label" name="firstName" required><button id="next" type="button" onclick="advance()">Continue</button></form>
          <script>\(failureScript)
          var step=0; function advance(){
            if(step===0){if(value.value!=='Sarah')return failSmokeTest(); step++;label.textContent='Email address';value.name='email';value.type='email';value.value='';next.textContent='Connect';next.disabled=true;setTimeout(()=>next.disabled=false,350)}
            else{if(value.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()}
          }</script>
          """, expected: .submitted),
        Scenario(name: "prechecked native and custom marketing declined", html: """
          <form><input id="email" type="email" required>
          <label><input id="offers" type="checkbox" checked>Receive marketing offers</label>
          <label><input id="optout" type="checkbox">Do not send marketing communications</label>
          <div id="custom" role="checkbox" aria-checked="true" aria-label="Receive marketing offers" onclick="this.setAttribute('aria-checked', this.getAttribute('aria-checked')==='true'?'false':'true')"></div>
          <button type="button" onclick="finish()">Connect</button></form>
          <script>\(failureScript)
          function finish(){if(!offers.checked && optout.checked && custom.getAttribute('aria-checked')==='false')document.body.textContent='Connected';else failSmokeTest()}</script>
          """, expected: .submitted),
        Scenario(name: "optional account payment and verification branch ignored", html: """
          <p>Premium users may pay or enter a verification code.</p>
          <form><input name="password" type="password" autocomplete="current-password" required><button type="button" onclick="failSmokeTest()">Sign in</button></form>
          <form><input id="email" type="email" required><button type="button" onclick="document.body.textContent='Connected'">Free guest Wi-Fi</button></form>
          <script>\(failureScript)</script>
          """, expected: .submitted),
        Scenario(name: "verification introduced after registration", html: """
          <form><input type="email" required><button type="button" onclick="next()">Continue</button></form>
          <script>\(failureScript)
          function next(){document.body.innerHTML='<form><input autocomplete="one-time-code" name="verification_code" required><button type="button" onclick="failSmokeTest()">Continue</button></form>'}</script>
          """, expected: .unsupported("verification_code_required")),
        Scenario(name: "open shadow-root portal controls", html: """
          <div id="portal"></div><script>\(failureScript)
          var root=portal.attachShadow({mode:'open'});root.innerHTML='<form><label>Email address<input id="guestEmail" type="email" required></label><button type="button">Connect</button></form>';
          root.querySelector('button').onclick=function(){if(root.querySelector('input').value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected';else failSmokeTest()};
          </script>
          """, expected: .submitted),
        Scenario(name: "same-origin frame portal controls", html: """
          <iframe id="portal" srcdoc="<form><input id='email' type='email' required><button type='button' onclick=&quot;if(email.value==='sarah.chen.wifi@gmail.com')document.body.textContent='Connected'&quot;>Connect</button></form>"></iframe>
          """, expected: .submitted),
        Scenario(name: "assisted completion reuses unresolved session", html: """
          <form><input id="reference" name="unresolvedReference" required><button type="button" onclick="if(reference.value==='local-test-value')document.body.textContent='Connected'">Connect</button></form>
          """, expected: .assisted),
        Scenario(name: "explicit free branch from returning login", html: """
          <form><input type="password" autocomplete="current-password" required><button type="button" onclick="failSmokeTest()">Sign in</button></form>
          <a href="#" onclick="document.body.innerHTML='<form><input type=email required><button type=button onclick=finish()>Connect</button></form>';return false">Free guest Wi-Fi</a>
          <script>\(failureScript) function finish(){document.body.textContent='Connected'}</script>
          """, expected: .submitted),
        Scenario(name: "cookies and action budget survive full navigation", html: "", expected: .submitted, useHTTP: true),
        Scenario(name: "slow JavaScript grant waits while action is busy", html: """
          <form><input type="email" required><button id="connect" type="button" onclick="connect.disabled=true;setTimeout(()=>document.body.textContent='Connected',3500)">Connect</button></form>
          """, expected: .submitted),
        Scenario(name: "Airport-shaped JavaScript registration", html: """
          <form class="custom-form" data-endpoint="lhrenroll">
          <input name="firstName" required><input name="lastName" required><input name="email" type="email" required>
          <label><input name="optBlobChecked" type="checkbox" checked>Receive marketing offers</label><button>Get online</button></form>
          <script>\(failureScript)
          document.querySelector('form').addEventListener('submit',function(event){event.preventDefault(); var fields=new FormData(this);if(fields.get('firstName')==='Sarah'&&fields.get('lastName')==='Chen'&&fields.get('email')==='sarah.chen.wifi@gmail.com'&&!fields.has('optBlobChecked'))document.body.textContent='Connected';else failSmokeTest()})
          </script>
          """, expected: .submitted),
    ]

    static func main() {
        let requiresLocalModel = ProcessInfo.processInfo.environment["WIFI_PORTAL_SMOKE_MODEL_ONLY"] == "1"
        let localModelAvailable = LocalPortalReasoner.makeAvailable() != nil
        if requiresLocalModel && !localModelAvailable {
            fail("Apple on-device model is unavailable; local-model verification cannot be skipped")
        }
        if CommandLine.arguments.contains("--wan-denied") { verifyWANIsDenied() }
        scriptURL = URL(fileURLWithPath: CommandLine.arguments[1])
        correctionLadderURL = URL(
            fileURLWithPath: CommandLine.arguments[2]
        )
        try? FileManager.default.createDirectory(
            at: lockDirectory,
            withIntermediateDirectories: true
        )
        scenarios.append(Scenario(name: "Hostile page cannot hook autofill or forge account messages", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/hostile/autofill", accountScope: "hostile-venue", expectedJourneyActions: 1))
        scenarios.append(Scenario(name: "Stale iframe authorization cannot fill a navigated document", html: "", expected: .submitted,
                                  staleFrameBoundary: true))
        scenarios.append(Scenario(name: "Same-origin iframe signup receives Persona password", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/iframe/same", accountScope: "iframe-same-venue", expectedJourneyActions: 1))
        scenarios.append(Scenario(name: "Same-origin srcdoc signup receives Persona password", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/iframe/srcdoc", accountScope: "iframe-srcdoc-venue", expectedJourneyActions: 1))
        scenarios.append(Scenario(name: "Cross-origin iframe withholds Persona password", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/iframe/cross", accountScope: "iframe-cross-venue", expectedJourneyActions: 1))
        scenarios.append(Scenario(name: "Opaque sandboxed iframe withholds Persona password", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/iframe/opaque", accountScope: "iframe-opaque-venue", expectedJourneyActions: 1))
        scenarios.append(Scenario(name: "Same-origin srcdoc preserves known account reasoning state", html: "", expected: .submitted,
                                  useHTTP: true, entryPath: "/iframe/srcdoc-login", accountScope: "iframe-login-venue",
                                  expectedServerActions: ["login"], seedAccount: true, expectedJourneyActions: 1, inspectAccountOperation: true))
        scenarios += [
            Scenario(name: "Marketing opt-out dropdown answers Yes", html: """
                <form onsubmit="if(document.querySelector('select').value==='yes')document.body.textContent='Connected';return false">
                <label>Do not send marketing <select name="marketing_opt_out" required><option value="no">No</option><option value="yes">Yes</option></select></label>
                <button>Connect</button></form>
                """, expected: .submitted),
            Scenario(name: "Marketing opt-out radio clears default No", html: """
                <form onsubmit="if(document.querySelector('input:checked').value==='yes')document.body.textContent='Connected';return false">
                <fieldset><legend>Do not send marketing</legend>
                <label><input name="marketing_opt_out" type="radio" value="no" checked required>No</label>
                <label><input name="marketing_opt_out" type="radio" value="yes" required>Yes</label></fieldset>
                <button>Connect</button></form>
                """, expected: .submitted),
            Scenario(name: "Disabled marketing refusal stops before submission", html: """
                <form onsubmit="document.body.textContent='Connected';return false">
                <label>Send marketing <select name="marketing" required><option value="yes">Yes</option><option value="no" disabled>No</option></select></label>
                <button>Connect</button></form>
                """, expected: .failed, stopBeforeAction: true),
            Scenario(name: "Marketing option follows visible label", html: """
                <form onsubmit="if(document.querySelector('select').value==='deny')document.body.textContent='Connected';return false">
                <label>Receive marketing <select name="marketing" required>
                <option value="allow" label="Receive marketing">No</option>
                <option value="deny" label="No thanks">Yes</option></select></label>
                <button>Connect</button></form>
                """, expected: .submitted)
        ]
        scenarios += ordinaryControlScenarios
        scenarios += [
            Scenario(name: "Unavailable HTTP page stops before filling", html: "", expected: .unsupported("portal_page_unavailable"),
                     useHTTP: true, stopBeforeAction: true, deterministicBypass: true, entryPath: "/unavailable/404"),
            Scenario(name: "Unavailable soft error page ignores signup navigation", html: "<title>Page Not Found - Example</title><form><input type='search' name='s'><button>Search</button></form><a href='/signup'>Register</a>", expected: .unsupported("portal_page_unavailable"), stopBeforeAction: true, deterministicBypass: true),
            Scenario(name: "Unavailable search page is not a Wi-Fi portal", html: "<title>Example website</title><form role='search'><input type='search' name='s'><button>Search</button></form>", expected: .unsupported("portal_page_unavailable"), stopBeforeAction: true, deterministicBypass: true)
        ]
        scenarios.append(Scenario(name: "Private captive gateway uses scoped transport across navigation", html: "", expected: .submitted,
                                  useHTTP: true, scopedTransport: true, fixtureHost: "10.254.254.254"))
        scenarios += [
            Scenario(name: "Vision Express account persistence after verified creation", html: "", expected: .submitted,
                     useHTTP: true, entryPath: "/vision/account-create", accountScope: "repeat-venue"),
            Scenario(name: "Vision Express account persistence skips registration on return", html: "", expected: .submitted,
                     useHTTP: true, entryPath: "/vision/account-return", accountScope: "repeat-venue", expectedServerActions: ["login"]),
            Scenario(name: "Vision Express account duplicate response recovers across navigation", html: "", expected: .submitted,
                     useHTTP: true, entryPath: "/vision/account-duplicate", accountScope: "duplicate-venue", expectedServerActions: ["duplicate", "login"])
        ]
        if localModelAvailable {
            scenarios += localModelScenarios
            scenarios += [
                Scenario(name: "Vision Express account state guides model to unfamiliar login control", html: "", expected: .submitted,
                         useHTTP: true, localModel: true, minimumReasoningRequests: 1, entryPath: "/vision/account-return-model",
                         accountScope: "model-return-venue", expectedServerActions: ["login"], seedAccount: true),
                Scenario(name: "Vision Express create account then login with Apple model", html: "", expected: .submitted,
                         useHTTP: true, localModel: true, minimumReasoningRequests: 2, entryPath: "/vision/auth"),
                Scenario(name: "Vision Express scoped Wi-Fi transport and Apple model", html: "", expected: .submitted,
                         useHTTP: true, localModel: true, minimumReasoningRequests: 2, entryPath: "/vision/auth", scopedTransport: true),
                Scenario(name: "Vision Express signup after portal origin redirect", html: "", expected: .submitted,
                         useHTTP: true, localModel: true, minimumReasoningRequests: 2, entryPath: "/vision/entry"),
                Scenario(name: "Vision Express slow page and stalled decoration", html: "", expected: .submitted,
                         useHTTP: true, localModel: true, minimumReasoningRequests: 2, entryPath: "/vision/slow-auth")
            ]
        } else {
            print("Apple on-device model scenarios: SKIP (model unavailable; deterministic tests still run)")
        }
        if let filter = ProcessInfo.processInfo.environment["WIFI_PORTAL_SMOKE_FILTER"] {
            scenarios = scenarios.filter { $0.name.contains(filter) }
        }
        if requiresLocalModel {
            scenarios = scenarios.filter(\.localModel)
        }
        guard !scenarios.isEmpty else {
            fail("No matching scenarios; verification requires at least one executed scenario")
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        runNextScenario()
        NSApplication.shared.run()
    }

    private static func verifyWANIsDenied() {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { fail("Could not check WAN isolation") }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        // TEST-NET-1 is a reserved documentation address. A working sandbox
        // rejects this syscall immediately, before any packet can be sent.
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(9).bigEndian
        address.sin_addr.s_addr = inet_addr("192.0.2.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let code = errno
        close(descriptor)
        guard result == -1, code == EPERM || code == EACCES else {
            fail("WAN-denial profile is not effective")
        }
        print("Outbound WAN connections: DENIED (loopback fixtures permitted)"); fflush(stdout)
    }

    private static func runNextScenario() {
        guard scenarioIndex < scenarios.count else {
            try? FileManager.default.removeItem(at: lockDirectory)
            print(
                "Native WebView smoke tests: PASS "
                    + "(\(scenarios.count) real WebKit scenarios)"
            )
            NSApplication.shared.terminate(nil)
            return
        }

        let scenario = scenarios[scenarioIndex]
        print("WebKit scenario: \(scenario.name)"); fflush(stdout)
        if scenario.staleFrameBoundary {
            let probe = StaleFrameBoundaryProbe(scriptURL: scriptURL)
            staleFrameProbe = probe
            let timeout = Task {
                try? await Task.sleep(for: .seconds(15))
                if !Task.isCancelled { fail("Stale iframe boundary probe did not complete") }
            }
            Task {
                do {
                    try await probe.run(base: URL(string: CommandLine.arguments[3])!)
                    timeout.cancel()
                    probe.discard()
                    staleFrameProbe = nil
                    scenarioIndex += 1
                    runNextScenario()
                } catch { fail("Stale iframe boundary: \(error)") }
            }
            return
        }
        let encoded = Data(scenario.html.utf8).base64EncodedString()
        let fixtureBase = scenario.scopedTransport
            ? CommandLine.arguments[3].replacingOccurrences(of: "127.0.0.1", with: scenario.fixtureHost)
            : CommandLine.arguments[3]
        guard let portalURL = URL(
            string: scenario.useHTTP ? fixtureBase + (scenario.entryPath ?? "/cookie/1") : "data:text/html;charset=utf-8;base64,\(encoded)"
        ) else {
            fail("\(scenario.name): invalid test URL")
        }
        let lockURL = lockDirectory.appendingPathComponent(
            "engine-\(scenarioIndex).lock"
        )
        guard let lock = SharedEngineLock.acquire(at: lockURL) else {
            fail("\(scenario.name): could not acquire engine lock")
        }
        var fixtureIdentity = FakeIdentity.sarahChen
        if scenario.accountScope != nil { fixtureIdentity.password = "Local-fixture-password-42!" }
        let accountStore = PortalAccountStore(file: lockDirectory.appendingPathComponent("accounts.json"))
        if scenario.seedAccount, let scope = scenario.accountScope {
            try! accountStore.remember(PortalCredentials(origin: portalURL.absoluteString, operation: .existing,
                username: fixtureIdentity.email, password: fixtureIdentity.password), scope: scope)
        }
        accountReasoner = scenario.inspectAccountOperation ? AccountBoundaryReasoner() : nil
        guard let created = WebViewAutopilotController(
            portalURL: portalURL,
            identity: fixtureIdentity,
            scriptURL: scriptURL,
            correctionLadderURL: correctionLadderURL,
            engineLock: lock,
            handoff: scenario.useHTTP ? WebViewHandoffRecord(portalURL: portalURL.absoluteString, venueFingerprint: "test", reason: "js_render", capturedHTMLPath: nil, writtenAt: Date().timeIntervalSince1970, cookies: [PortalSessionCookie(name: "portal-session", value: "fresh-session", domain: portalURL.host!, path: "/", secure: false, expires: nil)], networkInterface: scenario.scopedTransport ? "lo0" : nil) : nil,
            diagnosticsDirectory: lockDirectory,
            diagnosticLogURL: lockDirectory.appendingPathComponent("diagnostic-trace.log"),
            reasoner: accountReasoner ?? (scenario.localModel && ProcessInfo.processInfo.environment["WIFI_PORTAL_SMOKE_TRACE"] == "1" ? TraceLocalReasoner() : nil), useLocalReasoning: scenario.localModel || scenario.deterministicBypass,
            accountScope: scenario.accountScope,
            accountStore: accountStore,
            browserResolver: scenario.scopedTransport ? { @Sendable host, _ in
                guard ["portal.example.test", "10.254.254.254"].contains(host) else { throw CocoaError(.fileReadNoSuchFile) }
                return ["127.0.0.1"]
            } : nil,
            completion: { outcome in
                validate(outcome, for: scenario)
            }
        ) else {
            fail("\(scenario.name): could not create controller")
        }
        controller = created
        created.start()
    }

    private static func validate(
        _ outcome: WebViewAutopilotController.Outcome,
        for scenario: Scenario
    ) {
        if case .submitted = outcome {
            guard let view = controller?.webView else { fail("Missing retained browser") }
            // A candidate submission alone is not a passing fixture. Assert
            // the grant marker, including the active frame, independently.
            view.evaluateJavaScript("""
                (function connected(doc,depth){
                  if(doc.body && doc.body.innerText.trim()==='Connected')return true;
                  if(depth>=4)return false;
                  for(var frame of doc.querySelectorAll('iframe')){
                    try{if(frame.contentDocument && connected(frame.contentDocument,depth+1))return true}catch(_){}
                  }
                  return false;
                })(document,0)
                """) { raw, error in
                guard error == nil, raw as? Bool == true else {
                    fail("\(scenario.name): no actual fixture grant after submission")
                }
                if scenario.entryPath == "/hostile/autofill" {
                    view.evaluateJavaScript("""
                        hostileProbe.hookCalls === 0 && !hostileProbe.personaSeen
                          && hostileProbe.availableHandlers.length === 0
                          && window.__wifiAutologinAutofill.pageOwned === true
                          && typeof window.__wifiAutologinSchema === 'undefined'
                          && typeof window.__wifiAutologinReason === 'undefined'
                        """) { raw, error in
                        guard error == nil, raw as? Bool == true else {
                            fail("Hostile page accessed the executor, persona or native message handlers")
                        }
                        controller?.rememberVerifiedAccount()
                        let store = PortalAccountStore(file: lockDirectory.appendingPathComponent("accounts.json"))
                        guard let url = view.url, store.load(for: url, scope: scenario.accountScope) == nil else {
                            fail("Forged signup message persisted an account")
                        }
                        validateOutcome(outcome, for: scenario)
                    }
                    return
                }
                if scenario.entryPath?.hasPrefix("/vision/") == true {
                    Task {
                        let checked = try? await view.callAsyncJavaScript("""
                            const status=await (await fetch('/vision/access-check')).json();
                            const apple=await fetch('/vision/apple-probe'), microsoft=await fetch('/vision/microsoft-probe');
                            return status.online && JSON.stringify(status.actions)===JSON.stringify(expectedActions)
                              && (!slowPage || (status.decoration_pending && status.elapsed_seconds >= 37 && status.elapsed_seconds < 70))
                              && apple.ok && await apple.text()==='Success' && microsoft.ok && await microsoft.text()==='Microsoft Connect Test';
                            """, arguments: ["slowPage": scenario.entryPath == "/vision/slow-auth",
                                              "expectedActions": scenario.expectedServerActions], in: nil, contentWorld: .page)
                        guard checked as? Bool == true else { fail("\(scenario.name): server grant or independent probes failed") }
                        if let scope = scenario.accountScope, let url = view.url {
                            let store = PortalAccountStore(file: lockDirectory.appendingPathComponent("accounts.json"))
                            if scenario.expectedServerActions != ["login"] {
                                guard store.load(for: url, scope: scope) == nil else { fail("Account saved before verification") }
                            }
                            controller?.rememberVerifiedAccount()
                            guard store.load(for: url, scope: scope)?.password == "Local-fixture-password-42!" else {
                                fail("Verified account was not persisted")
                            }
                        }
                        print("Server verified \(scenario.expectedServerActions.joined(separator: " → ")) → grant; both independent connectivity probes passed")
                        validateOutcome(outcome, for: scenario)
                    }
                    return
                }
                if scenario.entryPath?.hasPrefix("/iframe/") == true, let scope = scenario.accountScope,
                   let url = view.url {
                    let store = PortalAccountStore(file: lockDirectory.appendingPathComponent("accounts.json"))
                    if !scenario.seedAccount {
                        guard store.load(for: url, scope: scope) == nil else { fail("Iframe account saved before verification") }
                    }
                    controller?.rememberVerifiedAccount()
                    let saved = store.load(for: url, scope: scope)
                    if ["/iframe/cross", "/iframe/opaque"].contains(scenario.entryPath) {
                        guard saved == nil else { fail("Third-party iframe authorized a Persona account") }
                    } else {
                        guard saved?.password == "Local-fixture-password-42!" else { fail("Same-origin iframe signup was not recorded") }
                    }
                }
                validateOutcome(outcome, for: scenario)
            }
            return
        }
        var stoppedFixture = scenario.stopBeforeAction
        if case .failed = scenario.expected { stoppedFixture = true }
        if case .unsupported = scenario.expected, scenario.localModel { stoppedFixture = true }
        if stoppedFixture {
            guard let view=controller?.webView else { fail("Missing stopped browser") }
            let check = scenario.localModel || scenario.stopBeforeAction ? "return field.value==='';" : "return !/^(unknown|verification_code|account_password|password)$/.test(intent) || field.value==='';"
            view.evaluateJavaScript("""
                Array.from(document.querySelectorAll('input,textarea')).every(function(field){
                  if(/hidden|checkbox|radio|submit|button/.test(field.type || ''))return true;
                  var api=window.__wifiAutologinAutofill;
                  var intent=api.classifyField(api.describeField(field,document));
                  \(check)
                })
                """, in: nil, in: WebViewAutopilotController.autofillWorld) { result in
                guard case let .success(raw) = result, raw as? Bool == true else { fail("\(scenario.name): a stopped credential field was filled") }
                validateOutcome(outcome,for:scenario)
            }
            return
        }
        validateOutcome(outcome, for: scenario)
    }

    private static func validateOutcome(
        _ outcome: WebViewAutopilotController.Outcome,
        for scenario: Scenario
    ) {
        if scenario.inspectAccountOperation {
            guard accountReasoner?.sawExistingAccount == true,
                  accountReasoner?.receivedSecret == false else {
                fail("Inherited frame lost native account state or exposed credentials to reasoning")
            }
        }
        if case .assisted = scenario.expected, !completingManually {
            let offersAssistance: Bool
            switch outcome {
            case .failed, .unsupported("unknown_required_field"): offersAssistance = true
            default: offersAssistance = false
            }
            guard offersAssistance, let controller,
                  let lock = SharedEngineLock.acquire(at: lockDirectory.appendingPathComponent("manual.lock")) else {
                fail("Unresolved stage did not offer assistance")
            }
            completingManually = true
            controller.showAssistedSignIn(lock: lock)
            guard let window = NSApplication.shared.windows.first(where: { $0.title == "Finish Wi-Fi sign-in" }),
                  let view = findWebView(window.contentView) else { fail("Assistance did not retain the browser") }
            window.orderOut(nil)
            view.evaluateJavaScript("reference.value='local-test-value';reference.dispatchEvent(new Event('input',{bubbles:true}));document.querySelector('button').click();") { _, error in
                guard error == nil else { fail("Could not complete the local manual fixture") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    controller.perform(NSSelectorFromString("verifyAssisted"))
                }
            }
            return
        }
        let matched: Bool
        switch (scenario.expected, outcome) {
        case (.submitted, .submitted), (.assisted, .submitted), (.failed, .failed):
            matched = true
        case let (.unsupported(expected), .unsupported(actual)):
            matched = expected == actual
        default:
            matched = false
        }
        guard matched else {
            fail("\(scenario.name): unexpected outcome \(describe(outcome))")
        }
        var mustStopBeforeAction = scenario.stopBeforeAction
        if case .failed = scenario.expected { mustStopBeforeAction = true }
        if case .unsupported = scenario.expected, scenario.localModel { mustStopBeforeAction = true }
        if mustStopBeforeAction {
            guard let path=controller?.diagnosticsURL, let data=try? Data(contentsOf:path),
                  let report=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let journey=report["journey"] as? [String:Any], journey["actions"] as? Int == 0 else {
                fail("\(scenario.name): unresolved fixture was acted on")
            }
        }
        if scenario.localModel {
            guard let path=controller?.diagnosticsURL, let data=try? Data(contentsOf:path),
                  let report=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let requests=report["local_reasoning_requests"] as? Int, requests > 0 && requests <= 12 && requests >= scenario.minimumReasoningRequests,
                  let resolutions=report["local_reasoning_decisions"] as? Int, resolutions > 0 && resolutions <= requests else {
                fail("\(scenario.name): on-device model was not exercised")
            }
            print("Apple on-device model: PASS \(scenario.name)")
        }
        if scenario.deterministicBypass {
            guard let path=controller?.diagnosticsURL, let data=try? Data(contentsOf:path),
                  let report=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  report["local_reasoning_requests"] as? Int == 0 else {
                fail("\(scenario.name): deterministic submit unnecessarily invoked the model")
            }
        }
        if completingManually {
            guard controller?.assisted == true, let path = controller?.diagnosticsURL,
                  let data = try? Data(contentsOf: path), let text = String(data: data, encoding: .utf8),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  report["source"] as? String == "assisted", !text.contains("local-test-value") else {
                fail("Manual result lost its attribution or recorded entered values")
            }
            completingManually = false
        }
        if scenario.useHTTP, case .submitted = scenario.expected {
            guard let path = controller?.diagnosticsURL, let data = try? Data(contentsOf: path),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let journey = report["journey"] as? [String: Any],
                  (journey["actions"] as? Int ?? 0) >= (scenario.expectedServerActions == ["login"] ? 1 : scenario.expectedJourneyActions) else {
                fail("\(scenario.name): journey lost its prior action history")
            }
        }
        if scenario.useHTTP && scenario.entryPath == nil && !scenario.scopedTransport {
            guard let path = controller?.diagnosticsURL, let data = try? Data(contentsOf: path),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let journey = report["journey"] as? [String: Any],
                  journey["actions"] as? Int == 2,
                  (journey["trace"] as? [[String: Any]])?.count == 2,
                  (report["navigations"] as? Int ?? 0) >= 2 else {
                fail("\(scenario.name): expected two actions across two loaded documents")
            }
        }
        if scenario.scopedTransport {
            guard let path = controller?.diagnosticsURL, let data = try? Data(contentsOf: path),
                  let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  report["browser_transport"] as? String == "wifi_scoped_connect",
                  (report["browser_proxy_connections"] as? Int ?? 0) >= (scenario.entryPath == "/vision/auth" ? 4 : 2) else {
                fail("\(scenario.name): browser bypassed the scoped transport")
            }
            print("Scoped transport: verified browser traffic through authenticated CONNECT relay")
        }
        controller?.discard()
        controller = nil
        scenarioIndex += 1
        DispatchQueue.main.async {
            runNextScenario()
        }
    }

    private static func findWebView(_ view: NSView?) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view?.subviews ?? [] { if let webView = findWebView(child) { return webView } }
        return nil
    }

    private static func describe(
        _ outcome: WebViewAutopilotController.Outcome
    ) -> String {
        switch outcome {
        case .submitted:
            return "submitted"
        case let .unsupported(reason):
            return "unsupported(\(reason))"
        case let .failed(detail):
            return "failed(\(detail))"
        }
    }

    private static func fail(_ message: String) -> Never {
        controller?.discard()
        try? FileManager.default.removeItem(at: lockDirectory)
        fputs("Native WebView smoke test failed: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
private final class StaleFrameBoundaryProbe: NSObject, WKScriptMessageHandler {
    private var view: WKWebView!
    private var expectedPath = ""
    private var waiter: CheckedContinuation<WKFrameInfo, Never>?
    private let schema: [String: Any]
    private let profiles: [String: Any]
    private enum Failure: Error { case assertion(String) }

    init(scriptURL: URL) {
        let resources = scriptURL.deletingLastPathComponent()
        let schemaData = try! Data(contentsOf: resources.appendingPathComponent("portal-schema.json"))
        let profilesData = try! Data(contentsOf: resources.appendingPathComponent("vendor-profiles.json"))
        schema = try! JSONSerialization.jsonObject(with: schemaData) as! [String: Any]
        profiles = try! JSONSerialization.jsonObject(with: profilesData) as! [String: Any]
        let script = "window.__wifiAutologinSchema = " + String(data: schemaData, encoding: .utf8)!
            + ";window.__wifiAutologinProfiles = " + String(data: profilesData, encoding: .utf8)!
            + ";\n" + (try! String(contentsOf: scriptURL, encoding: .utf8))
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let content = configuration.userContentController
        content.add(self, contentWorld: WebViewAutopilotController.autofillWorld, name: "frameBoundaryReady")
        content.addUserScript(WKUserScript(source: script + "\nwindow.webkit.messageHandlers.frameBoundaryReady.postMessage({});",
            injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: WebViewAutopilotController.autofillWorld))
        view = WKWebView(frame: .init(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !message.frameInfo.isMainFrame, message.frameInfo.request.url?.path == expectedPath,
              let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: message.frameInfo)
    }

    func run(base: URL) async throws {
        expectedPath = "/iframe/race-source"
        let staleFrame = await withCheckedContinuation { continuation in
            waiter = continuation
            view.load(URLRequest(url: base.appendingPathComponent("iframe/race-parent")))
        }
        let oldURL = staleFrame.request.url!
        var target = URLComponents(url: base.appendingPathComponent("iframe/race-target"), resolvingAgainstBaseURL: false)!
        target.host = "localhost"
        expectedPath = "/iframe/race-target"
        let freshFrame = await withCheckedContinuation { continuation in
            waiter = continuation
            Task {
                _ = try? await view.callAsyncJavaScript("document.querySelector('iframe').src = target;",
                    arguments: ["target": target.url!.absoluteString], in: nil, contentWorld: .page)
            }
        }
        // Establish the actual API behavior without any timing race: the old
        // frame object now addresses the fully loaded cross-origin document.
        let currentOrigin = try await view.callAsyncJavaScript("return globalThis.origin;", arguments: [:],
            in: staleFrame, contentWorld: WebViewAutopilotController.autofillWorld) as? String
        guard currentOrigin?.contains("localhost") == true else { throw Failure.assertion("Old frame did not target the replacement document") }
        let started = Date().timeIntervalSince1970 * 1000
        var arguments: [String: Any] = [
            "expectedFrameURL": oldURL.absoluteString,
            "identity": FakeIdentity.sarahChen.javascriptDictionary,
            "credentials": ["operation": "existing", "username": "boundary@example.test", "password": "stale-frame-secret"],
            "corrections": [:], "schema": schema, "profiles": profiles, "correctionLadder": [:],
            "journey": ["actions": 3, "trace": [], "attempts": [:]], "maximumActions": 8,
            "deadline": started + 10000, "startedAt": started,
        ]
        let stopped = try await view.callAsyncJavaScript(WebViewAutopilotController.guardedAutofillScript,
            arguments: arguments, in: staleFrame, contentWorld: WebViewAutopilotController.autofillWorld) as? [String: Any]
        guard stopped?["detail"] as? String == "frame_origin_changed",
              (stopped?["journey"] as? [String: Any])?["actions"] as? Int == 3 else {
            throw Failure.assertion("Stale origin was accepted or journey history was reset")
        }
        let untouched = try await view.callAsyncJavaScript("return !window.raceReceipt && document.querySelector('#email').value === '' && document.querySelector('#password').value === '';",
            arguments: [:], in: freshFrame, contentWorld: .page) as? Bool
        guard untouched == true else { throw Failure.assertion("Replacement document received stale credentials") }
        // Positive control uses the same production executor and current frame.
        arguments["expectedFrameURL"] = target.url!.absoluteString
        let accepted = try await view.callAsyncJavaScript(WebViewAutopilotController.guardedAutofillScript,
            arguments: arguments, in: freshFrame, contentWorld: WebViewAutopilotController.autofillWorld) as? [String: Any]
        let filled = try await view.callAsyncJavaScript("return window.raceReceipt && raceReceipt.email === 'boundary@example.test' && raceReceipt.password === 'stale-frame-secret';",
            arguments: [:], in: freshFrame, contentWorld: .page) as? Bool
        guard accepted?["status"] as? String == "submitted", filled == true else {
            throw Failure.assertion("Matching origin did not allow legitimate autofill")
        }
    }

    func discard() {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "frameBoundaryReady", contentWorld: WebViewAutopilotController.autofillWorld)
        view.stopLoading()
        view = nil
    }
}

@MainActor
private final class AccountBoundaryReasoner: LocalPortalReasoning {
    private(set) var sawExistingAccount = false
    private(set) var receivedSecret = false

    func resolve(_ request: PortalReasoningRequest) async -> PortalReasoningDecision? {
        if let data = try? JSONEncoder().encode(request), let text = String(data: data, encoding: .utf8) {
            receivedSecret = receivedSecret || text.contains("Local-fixture-password-42!")
                || text.contains("sarah.chen.wifi@gmail.com")
        }
        guard request.mode == "action", request.accountOperation == "existing" else { return nil }
        sawExistingAccount = true
        // A deterministic spy verifies native account metadata, separately
        // from the suite's actual Apple-model inference scenarios.
        guard let offered = request.choices.first(where: { $0.label.contains("Accéder") }) else { return nil }
        return PortalReasoningDecision(choice: offered.key)
    }
}

@MainActor
private final class TraceLocalReasoner: LocalPortalReasoning {
    private let delegate = LocalPortalReasoner.makeAvailable()
    func resolve(_ request: PortalReasoningRequest) async -> PortalReasoningDecision? {
        if ProcessInfo.processInfo.environment["WIFI_PORTAL_SMOKE_TRACE"] == "1" {
            print(request); fflush(stdout)
        }
        let result = await delegate?.resolve(request)
        if ProcessInfo.processInfo.environment["WIFI_PORTAL_SMOKE_TRACE"] == "1" {
            print(result as Any); fflush(stdout)
        }
        return result
    }
}

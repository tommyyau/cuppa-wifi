import Darwin
import Foundation
import Security

private struct Request: Sendable {
    var method: String
    var target: String
    var headers: [String: String]
    var body: String
    var path: String { URLComponents(string: target)?.path ?? target }
    var values: [String: String] {
        var result: [String: String] = [:]
        for pair in body.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            func decode(_ value: Substring) -> String {
                String(value).replacingOccurrences(of: "+", with: " ").removingPercentEncoding
                    ?? String(value)
            }
            let key = decode(parts[0])
            let value = decode(parts[1])
            if result[key] == nil && !value.isEmpty { result[key] = value }
        }
        return result
    }
}
private struct Response: Sendable {
    var text: String
    var status = 200
    var headers: [(String, String)] = []
    var contentType = "text/html; charset=utf-8"
}
private actor FixtureState {
    private struct Account: Equatable {
        var email: String
        var password: String
    }
    private final class Session {
        var csrf = FixtureState.token(bytes: 8)
        var actions: [String] = []
        var online = false
        let startedAt = ProcessInfo.processInfo.systemUptime
        let mode: String
        var account: Account?
        var decorationRequested = false
        var decorationFinished = false
        init(mode: String) { self.mode = mode }
    }
    let visionHTML: String
    let hostileHTML: String
    let port: UInt16
    private var sessions: [String: Session] = [:]
    private var rememberedAccount: Account?
    private let existingAccount = Account(
        email: "sarah.chen.wifi@gmail.com", password: "Local-fixture-password-42!")
    init(visionHTML: String, hostileHTML: String, port: UInt16) {
        self.visionHTML = visionHTML
        self.hostileHTML = hostileHTML
        self.port = port
    }
    static func token(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private func session(_ request: Request) -> Session? {
        for part in (request.headers["cookie"] ?? "").split(separator: ";") {
            let cookie = part.trimmingCharacters(in: .whitespaces)
            if cookie.hasPrefix("vision-session=") {
                return sessions[String(cookie.dropFirst("vision-session=".count))]
            }
        }
        return nil
    }
    func handle(_ request: Request) async -> Response {
        if request.method == "GET" {
            if request.path == "/hostile/autofill" { return Response(text: hostileHTML) }
            if request.path.hasPrefix("/iframe/") { return iframeGET(request) }
            if request.target == "/unavailable/404" {
                return Response(
                    text:
                        "<title>Guest Wi-Fi</title><form action=\"/must-not-submit\"><input name=\"email\"><button>Connect</button></form>",
                    status: 404)
            }
            if request.target == "/vision/entry" {
                return Response(
                    text: "", status: 302,
                    headers: [("Location", "http://localhost:\(port)/vision/auth")])
            }
            if request.target.hasPrefix("/vision/") { return await visionGET(request) }
            let html: String
            if !(request.headers["cookie"] ?? "").contains("portal-session=fresh-session") {
                html =
                    "<form><input autocomplete=\"one-time-code\" required><button>Continue</button></form>"
            } else if request.target == "/cookie/1" {
                html =
                    #"<form id="guest"><input id="email" type="email" required><input name="csrf" type="hidden" value="token-one"><button type="button" onclick="if(email.value==='sarah.chen.wifi@gmail.com') location.href='/cookie/2'; else location.href='/wrong'">Continue</button></form>"#
            } else if request.target == "/cookie/2" {
                html =
                    #"<form><input id="csrf" name="csrf" type="hidden" value="token-two"><label><input id="terms" type="checkbox" required>Accept terms and conditions</label><button type="button" onclick="if(terms.checked && csrf.value==='token-two') document.body.textContent='Connected'; else location.href='/wrong'">Get online</button></form>"#
            } else {
                html =
                    "<form><input autocomplete=\"one-time-code\" required><button>Continue</button></form>"
            }
            return Response(text: html, contentType: "text/html")
        }
        if request.method == "POST" { return visionPOST(request) }
        return Response(text: "Unsupported request", status: 400)
    }
    /// The fixture grants only after inspecting the actual DOM values. The
    /// cross-origin form deliberately permits an empty password to prove it was
    /// withheld, while same-origin registration requires the exact test secret.
    private func iframeGET(_ request: Request) -> Response {
        if request.path == "/iframe/race-parent" {
            return Response(text: "<iframe src='/iframe/race-source'></iframe>")
        }
        if ["/iframe/race-source", "/iframe/race-target"].contains(request.path) {
            return Response(text: """
            <form><h1>Sign in</h1><input id="email" type="email" required>
            <input id="password" type="password" autocomplete="current-password" required>
            <button type="button" onclick="window.raceReceipt={email:email.value,password:password.value};document.body.textContent='Connected'">Sign in</button></form>
            """)
        }
        let withheld = request.path.hasSuffix("withheld")
        let existing = request.path == "/iframe/srcdoc-login"
        let check = withheld ? "password.value===''" : "password.value==='Local-fixture-password-42!'"
        let signup = """
        <form><h1>\(existing ? "Sign in" : "Create account")</h1><input id="email" type="email" required>
        <input id="password" type="password" autocomplete="\(existing ? "current-password" : "new-password")" \(withheld ? "" : "required")>
        <button type="button" onclick="if(email.value==='sarah.chen.wifi@gmail.com' && \(check)){document.body.textContent='Connected';parent.postMessage('Connected','*')}">\(existing ? "Accéder à mon espace" : "Create account")</button></form>
        """
        if request.path.hasPrefix("/iframe/signup") { return Response(text: signup) }
        let listener = "<script>addEventListener('message',function(e){var frame=document.querySelector('iframe');if(e.source===frame.contentWindow && e.data==='Connected'){frame.hidden=true;document.body.appendChild(document.createTextNode('Connected'))}})</script>"
        if request.path.hasPrefix("/iframe/srcdoc") {
            let escaped = signup.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return Response(text: listener + "<iframe srcdoc=\"\(escaped)\"></iframe>")
        }
        let source = request.path == "/iframe/cross"
            ? "http://localhost:\(port)/iframe/signup-withheld"
            : request.path == "/iframe/opaque" ? "/iframe/signup-withheld" : "/iframe/signup"
        let sandbox = request.path == "/iframe/opaque" ? " sandbox=\"allow-scripts\"" : ""
        return Response(text: listener + "<iframe\(sandbox) src=\"\(source)\"></iframe>")
    }

    private func visionGET(_ request: Request) async -> Response {
        let path = request.path
        if [
            "/vision/auth", "/vision/slow-auth", "/vision/account-create", "/vision/account-return",
            "/vision/account-return-model", "/vision/account-duplicate",
        ].contains(path) {
            let key = Self.token(bytes: 16)
            let session = Session(mode: path)
            sessions[key] = session
            if path == "/vision/account-return" {
                guard let rememberedAccount else {
                    return Response(text: "No previous registration", status: 403)
                }
                session.account = rememberedAccount
            } else if ["/vision/account-duplicate", "/vision/account-return-model"].contains(path) {
                session.account = existingAccount
            }
            var html = visionHTML.replacingOccurrences(of: "FIXTURE_CSRF", with: session.csrf)
            if path.hasPrefix("/vision/account-") {
                html = html.replacingOccurrences(
                    of: "id=\"user_name\"", with: "id=\"user_name\" autocomplete=\"name\"")
            }
            if path == "/vision/account-return-model" {
                html = html.replacingOccurrences(
                    of: #"<input type="submit" name="commit" value="Sign In" id="sign_in">"#,
                    with:
                        #"<button type="button" onclick="this.form.requestSubmit()">Accéder à mon espace</button>"#
                )
            }
            if path == "/vision/slow-auth" {
                try? await Task.sleep(for: .seconds(37))
                html += #"<img src="/vision/slow-decoration" alt="">"#
            }
            return Response(
                text: html,
                headers: [("Set-Cookie", "vision-session=\(key); HttpOnly; Path=/vision/")])
        }
        guard let session = session(request) else {
            return Response(text: "Missing session", status: 403)
        }
        if path == "/vision/slow-decoration" {
            session.decorationRequested = true
            try? await Task.sleep(for: .seconds(70))
            session.decorationFinished = true
            return Response(text: "", status: 204)
        }
        if path == "/vision/login" {
            guard session.account != nil else {
                return Response(text: "Create an account first", status: 403)
            }
            return Response(
                text: visionHTML.components(separatedBy: #"<div class="form_links">"#)[0]
                    .replacingOccurrences(of: "FIXTURE_CSRF", with: session.csrf))
        }
        if path == "/vision/connected" && session.online { return Response(text: "Connected") }
        if ["/vision/apple-probe", "/vision/microsoft-probe"].contains(path) {
            guard session.online else { return Response(text: "Captive", status: 403) }
            return Response(
                text: path.hasSuffix("apple-probe") ? "Success" : "Microsoft Connect Test")
        }
        if path == "/vision/access-check" {
            let result: [String: Any] = [
                "online": session.online, "actions": session.actions,
                "decoration_pending": session.decorationRequested && !session.decorationFinished,
                "elapsed_seconds": ProcessInfo.processInfo.systemUptime - session.startedAt,
            ]
            let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            return Response(text: String(decoding: data, as: UTF8.self))
        }
        return Response(text: "Captive", status: 403)
    }
    private func visionPOST(_ request: Request) -> Response {
        guard let session = session(request) else {
            return Response(text: "Missing session", status: 403)
        }
        let values = request.values
        func value(_ key: String) -> String { values[key] ?? "" }
        guard value("csrf") == session.csrf else {
            return Response(text: "Invalid session token", status: 403)
        }
        if request.target == "/vision/signup" {
            if ["/vision/account-return", "/vision/account-return-model"].contains(session.mode) {
                return Response(text: "Returning visit must not register again", status: 409)
            }
            guard session.actions.isEmpty, value("user[name]") == "Sarah Chen",
                value("user[email]") == "sarah.chen.wifi@gmail.com",
                value("user[email_confirmation]") == value("user[email]"),
                value("user[password]").count >= 12,
                value("user[password_confirmation]") == value("user[password]")
            else {
                return Response(
                    text: #"<p class="error">Invalid registration fields or workflow order</p>"#,
                    status: 422)
            }
            if session.mode == "/vision/account-duplicate" {
                session.actions.append("duplicate")
                var html = visionHTML.replacingOccurrences(of: "FIXTURE_CSRF", with: session.csrf)
                html = html.replacingOccurrences(
                    of: #"id="signin_form" class="formarea""#,
                    with: #"id="signin_form" class="formarea" style="display:none""#)
                html = html.replacingOccurrences(
                    of: "class=\"formarea\" style=\"display:none\">\n  <h2>",
                    with:
                        "class=\"formarea\">\n  <p class=\"error\">Email has already been taken</p><h2>"
                )
                return Response(text: html)
            }
            session.account = Account(
                email: value("user[email]"), password: value("user[password]"))
            if session.mode == "/vision/account-create" { rememberedAccount = session.account }
            session.actions.append("signup")
            session.csrf = Self.token(bytes: 8)
            return Response(text: "", status: 303, headers: [("Location", "/vision/login")])
        }
        if request.target == "/vision/login" {
            let expected: [String] =
                [
                    "/vision/account-return": [], "/vision/account-return-model": [],
                    "/vision/account-duplicate": ["duplicate"],
                ][session.mode] ?? ["signup"]
            guard session.actions == expected,
                Account(email: value("email"), password: value("password")) == session.account,
                !value("terms").isEmpty
            else {
                return Response(
                    text:
                        #"<p class="error">Account must be created before login; credentials and terms must match</p>"#,
                    status: 422)
            }
            session.actions.append("login")
            session.online = true
            return Response(text: "", status: 303, headers: [("Location", "/vision/connected")])
        }
        return Response(text: "Unsupported request", status: 400)
    }
}
private final class FixtureServer: @unchecked Sendable {
    let socketFD: Int32
    let port: UInt16
    let state: FixtureState
    init(html: String, hostileHTML: String) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        guard
            withUnsafePointer(
                to: &address,
                {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }) == 0, listen(fd, 32) == 0
        else {
            close(fd)
            throw POSIXError(.EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
        state = FixtureState(visionHTML: html, hostileHTML: hostileHTML, port: port)
    }
    func serve() {
        while true {
            let client = accept(socketFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 120, tv_usec: 0)
            _ = setsockopt(
                client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(
                client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.global().async { [state] in
                guard let request = Self.read(client) else {
                    close(client)
                    return
                }
                Task {
                    let response = await state.handle(request)
                    Self.reply(client, response)
                    close(client)
                }
            }
        }
    }
    private static func read(_ fd: Int32) -> Request? {
        var header = Data()
        var byte: UInt8 = 0
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]) && header.count <= 16_384 {
            guard recv(fd, &byte, 1, 0) == 1 else { return nil }
            header.append(byte)
        }
        guard header.count <= 16_384 else { return nil }
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        let count = min(16_384, max(0, Int(headers["content-length"] ?? "0") ?? 0))
        var body = Data()
        while body.count < count {
            var buffer = [UInt8](repeating: 0, count: min(4096, count - body.count))
            let received = recv(fd, &buffer, buffer.count, 0)
            guard received > 0 else { return nil }
            body.append(contentsOf: buffer.prefix(received))
        }
        return Request(
            method: String(first[0]), target: String(first[1]), headers: headers,
            body: String(decoding: body, as: UTF8.self))
    }
    private static func reply(_ fd: Int32, _ response: Response) {
        let body = Data(response.text.utf8)
        let reason =
            [
                200: "OK", 204: "No Content", 302: "Found", 303: "See Other", 400: "Bad Request",
                403: "Forbidden", 404: "Not Found", 409: "Conflict", 422: "Unprocessable Entity",
            ][response.status] ?? "Response"
        var wire = Data(
            "HTTP/1.1 \(response.status) \(reason)\r\nContent-Type: \(response.contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                .utf8)
        for (key, value) in response.headers { wire.append(Data("\(key): \(value)\r\n".utf8)) }
        wire.append(Data("\r\n".utf8))
        wire.append(body)
        wire.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = send(
                    fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if written <= 0 { return }
                offset += written
            }
        }
    }
}
let arguments = CommandLine.arguments
if arguments.count != 3 {
    fputs("Usage: CuppaFixtureServer READY_FILE FIXTURES_DIRECTORY_OR_HTML_FILE\n", stderr)
    exit(2)
}
do {
    let fixtures = URL(fileURLWithPath: arguments[2])
    let htmlURL =
        fixtures.pathExtension == "html"
        ? fixtures : fixtures.appendingPathComponent("vision-express.html")
    let hostileURL = htmlURL.deletingLastPathComponent().appendingPathComponent("hostile-autofill.html")
    let server = try FixtureServer(html: String(contentsOf: htmlURL, encoding: .utf8),
                                  hostileHTML: String(contentsOf: hostileURL, encoding: .utf8))
    let ready = URL(fileURLWithPath: arguments[1])
    try Data("http://127.0.0.1:\(server.port)".utf8).write(to: ready, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ready.path)
    server.serve()
} catch {
    fputs("Fixture server could not start.\n", stderr)
    exit(1)
}

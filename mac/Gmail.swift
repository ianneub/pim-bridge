// Gmail through the Gmail API, for Ian's Google Workspace accounts.
//
// The bridge owns the Google sign-in for every client (MCP, the gmail CLI, and
// MenuWidgets over the socket), so signing out anywhere signs out everywhere:
//   - one OAuth client, a Google "Desktop app" client saved as downloaded to
//     gmail-oauth-client.json;
//   - the account list (name + email) in gmail-accounts.json;
//   - one refresh token per account in the login keychain, written with SecItem so only
//     this app's signature can read it back. /usr/bin/security would be trusted to read
//     it with no prompt, and a gmail.modify token can send mail.
//
// Scope gmail.modify: read, search, drafts, trash. It could send; this server has no tool
// that sends, deletes a draft, or deletes permanently (which the scope can't do anyway).
// Trash over HTTP needs Touch ID with no password fallback; from MenuWidgets' socket it
// doesn't. Every trash and untrash goes in gmail-trash-log.jsonl, kept 90 days.
//
// Tool calls run on `gmailQueue`, a concurrent queue, so slow Google replies and the
// Touch ID prompt don't hold up Reminders, Calendar or Contacts. Shared state is under
// `gmailLock`.

import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Network
import Security

let gmailQueue = DispatchQueue(label: "pim-bridge.gmail", attributes: .concurrent)
let gmailLock = NSLock()

func locked<T>(_ body: () throws -> T) rethrows -> T {
    gmailLock.lock()
    defer { gmailLock.unlock() }
    return try body()
}

let gmailClientURL = supportDir.appendingPathComponent("gmail-oauth-client.json")
let gmailAccountsURL = supportDir.appendingPathComponent("gmail-accounts.json")
let trashLogURL = supportDir.appendingPathComponent("gmail-trash-log.jsonl")
let gmailAPI = "https://gmail.googleapis.com/gmail/v1/users/me"
let gmailScope = "https://www.googleapis.com/auth/gmail.modify"
let trashLogDays = 90.0

func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}

// MARK: - Accounts

struct GmailAccount: Codable {
    var name: String
    var email: String
}

var gmailAccounts: [GmailAccount] = (try? Data(contentsOf: gmailAccountsURL))
    .flatMap { try? JSONDecoder().decode([GmailAccount].self, from: $0) } ?? []

func saveAccounts() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try writePrivate(try encoder.encode(gmailAccounts), to: gmailAccountsURL)
}

func accountList() -> String {
    gmailAccounts.isEmpty ? "none yet (sign_in adds one)" : gmailAccounts.map { "\($0.name) (\($0.email))" }.joined(separator: ", ")
}

/// `account` as an email or a name, either case.
func resolveAccount(_ args: [String: Any]) throws -> GmailAccount {
    guard let ref = (args["account"] as? String)?.trimmingCharacters(in: .whitespaces), !ref.isEmpty else {
        throw ToolError(message: "Say which account: \(locked { accountList() })")
    }
    return try locked {
        guard let account = gmailAccounts.first(where: { $0.email.caseInsensitiveCompare(ref) == .orderedSame })
            ?? gmailAccounts.first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame })
        else { throw ToolError(message: "No Gmail account \"\(ref)\". Accounts: \(accountList())") }
        return account
    }
}

// MARK: - OAuth client and tokens

struct OAuthClient {
    let id: String
    let secret: String
}

/// The JSON the Cloud console downloads (`{"installed": {...}}`).
func loadClient() -> OAuthClient? {
    guard let data = try? Data(contentsOf: gmailClientURL),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let body = (object["installed"] ?? object["web"]) as? [String: Any] ?? object
    guard let id = body["client_id"] as? String, !id.isEmpty else { return nil }
    return OAuthClient(id: id, secret: body["client_secret"] as? String ?? "")
}

func requireClient() throws -> OAuthClient {
    guard let client = loadClient() else {
        throw ToolError(message: "Gmail isn't set up: save the Google Cloud \"Desktop app\" OAuth client JSON as "
                        + "\(gmailClientURL.path) (mode 0600)")
    }
    return client
}

/// Refresh tokens in the login keychain. Items SecItem creates trust only the app that
/// made them (its designated requirement: identifier plus certificate), so anything else
/// gets a password prompt. Without a Team ID the item's partition is the build's cdhash,
/// so the first read after a rebuild prompts once too ("Always Allow" adds the new build).
enum TokenStore {
    static let service = "com.ianneub.pim-bridge.gmail-token"

    static func query(_ email: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: email]
    }

    /// The token, "" when there's no item, or nil when the read failed (say the prompt
    /// after a rebuild was cancelled), so it isn't remembered as signed out.
    static func read(_ email: String) -> String? {
        var q = query(email)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = out as? Data else {
            log("gmail: keychain read for \(email) failed: \(status)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Always a new item, never an update: a new item's access list holds this app alone,
    /// while an update keeps whatever else the old item had been allowed.
    static func save(_ email: String, _ token: String) throws {
        delete(email)
        var q = query(email)
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrLabel as String] = "PIM Bridge Gmail (\(email))"
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw ToolError(message: "Couldn't save the sign-in to the keychain (\(status))") }
    }

    /// Apps besides this one that the item lets read the token, or nil when its access
    /// list can't be read. Normally empty; an app someone chose "Always Allow" for on a
    /// keychain prompt (say /usr/bin/security) shows up here.
    static func otherReaders(_ email: String) -> [String]? {
        var q = query(email)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var ref: CFTypeRef?
        var access: SecAccess?
        guard SecItemCopyMatching(q as CFDictionary, &ref) == errSecSuccess, let item = ref,
              SecKeychainItemCopyAccess(item as! SecKeychainItem, &access) == errSecSuccess, let access = access,
              let acls = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL]
        else { return nil }
        var others: [String] = []
        var ownEntries = 0
        for acl in acls {
            var apps: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &apps, &description, &prompt) == errSecSuccess else { return nil }
            guard let list = apps as? [SecTrustedApplication] else {
                others.append("any application")
                continue
            }
            for app in list {
                var data: CFData?
                SecTrustedApplicationCopyData(app, &data)
                let path = (data as Data?).map { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } ?? ""
                if path == Bundle.main.bundlePath { ownEntries += 1 } else { others.append(path.isEmpty ? "an unknown app" : path) }
            }
        }
        // A second entry for this app is an older signature (say, the certificate before
        // a switch); rewriting the item drops it and the old builds' partitions.
        if ownEntries > 1 { others.append("an older signature of PIM Bridge") }
        return others
    }

    static func delete(_ email: String) {
        SecItemDelete(query(email) as CFDictionary)
    }
}


/// Refresh tokens read from the keychain so far; an empty string means there's none.
var refreshTokens: [String: String] = [:]
var accessTokens: [String: (token: String, expires: Date)] = [:]
/// Why an account needs signing in again, or how its last sign-in failed.
var accountProblems: [String: String] = [:]

/// One keychain read at a time. The login keychain ties each item to the build that
/// wrote it (its cdhash partition), so after a rebuild the first read asks for the login
/// password; concurrent reads would each ask.
let keychainLock = NSLock()

func refreshToken(_ email: String) -> String? {
    if let known = locked({ refreshTokens[email] }) { return known.isEmpty ? nil : known }
    keychainLock.lock()
    defer { keychainLock.unlock() }
    if let known = locked({ refreshTokens[email] }) { return known.isEmpty ? nil : known }
    guard let token = TokenStore.read(email) else { return nil }
    if !token.isEmpty { guardAccess(email, token) }
    locked { refreshTokens[email] = token }
    return token.isEmpty ? nil : token
}

/// Makes sure only this app can read the item: if anything else was allowed, writes the
/// token back as a new item, whose access list holds this app alone.
func guardAccess(_ email: String, _ token: String) {
    guard let others = TokenStore.otherReaders(email), !others.isEmpty else { return }
    log("gmail: keychain item for \(email) also let \(others.joined(separator: ", ")) read it; rewriting it for PIM Bridge alone")
    do {
        try TokenStore.save(email, token)
        if let left = TokenStore.otherReaders(email), !left.isEmpty {
            log("gmail: keychain item for \(email) still lets \(left.joined(separator: ", ")) read it")
        }
    } catch {
        log("gmail: couldn't rewrite the keychain item for \(email): \(error)")
    }
}

func forgetTokens(_ email: String) {
    TokenStore.delete(email)
    locked {
        refreshTokens[email] = ""
        accessTokens[email] = nil
        metadataCache = metadataCache.filter { !$0.key.hasPrefix(email + "/") }
    }
}

func formBody(_ fields: [(String, String)]) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return Data(fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? $1)" }
        .joined(separator: "&").utf8)
}

struct HTTPReply {
    let status: Int
    let data: Data
    var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
}

func send(_ request: URLRequest) throws -> HTTPReply {
    var request = request
    request.timeoutInterval = 30
    let done = DispatchSemaphore(value: 0)
    var reply: HTTPReply?
    var failure: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        reply = (response as? HTTPURLResponse).map { HTTPReply(status: $0.statusCode, data: data ?? Data()) }
        failure = error
        done.signal()
    }.resume()
    done.wait()
    guard let result = reply else { throw ToolError(message: "Can't reach Google: \(failure?.localizedDescription ?? "no reply")") }
    return result
}

/// Google's token endpoint: (access token, seconds it lasts, refresh token, scope).
func tokenRequest(_ fields: [(String, String)]) throws -> [String: Any] {
    var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = formBody(fields)
    return try send(request).json
}

func accessToken(_ account: GmailAccount) throws -> String {
    let email = account.email
    if let cached = locked({ accessTokens[email] }), cached.expires > Date() { return cached.token }
    guard let refresh = refreshToken(email) else {
        throw ToolError(message: "\(email) isn't signed in to PIM Bridge; ask Ian to sign it in (sign_in)")
    }
    let client = try requireClient()
    let reply = try tokenRequest([("client_id", client.id), ("client_secret", client.secret),
                                  ("refresh_token", refresh), ("grant_type", "refresh_token")])
    if reply["error"] as? String == "invalid_grant" {
        forgetTokens(email)
        locked { accountProblems[email] = "Google ended the sign-in; sign in again" }
        log("gmail: \(email) refresh token rejected (invalid_grant); needs sign-in")
        throw ToolError(message: "Google ended \(email)'s sign-in; ask Ian to sign it in again (sign_in)")
    }
    guard let token = reply["access_token"] as? String else {
        throw ToolError(message: "Google refused a token for \(email): \(reply["error_description"] ?? reply["error"] ?? "no reason given")")
    }
    let lifetime = (reply["expires_in"] as? Double) ?? 3600
    locked { accessTokens[email] = (token, Date().addingTimeInterval(lifetime - 60)) }
    return token
}

/// A message, thread or draft id, checked before it goes into a URL path: Gmail's are
/// letters, digits, - and _, and anything else (say "send?") could reach another endpoint.
func gmailID(_ value: Any?, _ what: String) throws -> String {
    guard let id = (value as? String)?.trimmingCharacters(in: .whitespaces), !id.isEmpty else {
        throw ToolError(message: "Pass \(what)")
    }
    guard id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }) else {
        throw ToolError(message: "\"\(id)\" isn't a Gmail id")
    }
    return id
}

/// One Gmail API call, as JSON. A 401 drops the access token and tries once more.
func gmail(_ account: GmailAccount, _ path: String, method: String = "GET",
           query: [URLQueryItem] = [], body: Any? = nil, retried: Bool = false) throws -> [String: Any] {
    var components = URLComponents(string: gmailAPI + path)!
    if !query.isEmpty {
        components.queryItems = query
        // Google reads a bare + in a query as a space ("from:a+b@x.com").
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    var request = URLRequest(url: components.url!)
    request.httpMethod = method
    request.setValue("Bearer \(try accessToken(account))", forHTTPHeaderField: "Authorization")
    if let body = body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let reply = try send(request)
    if reply.status == 401 && !retried {
        locked { accessTokens[account.email] = nil }
        return try gmail(account, path, method: method, query: query, body: body, retried: true)
    }
    guard (200..<300).contains(reply.status) else {
        let message = (reply.json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(reply.status)"
        throw GmailAPIError(status: reply.status, message: "Gmail (\(account.email)): \(message)")
    }
    return reply.json
}

struct GmailAPIError: Error {
    let status: Int
    let message: String
}

/// Runs `body` for each item, a few at a time; results keep the input order.
func concurrently<T, R>(_ items: [T], _ body: (T) throws -> R) throws -> [R] {
    let resultLock = NSLock()
    var results = [Result<R, Error>?](repeating: nil, count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { i in
        let r = Result { try body(items[i]) }
        resultLock.lock(); results[i] = r; resultLock.unlock()
    }
    return try results.map { try $0!.get() }
}

// MARK: - Sign-in

/// The browser half of Google sign-in: listen on 127.0.0.1, send the browser to Google
/// (PKCE, offline access, login_hint), take the code from the redirect, trade it for
/// tokens, and check the browser signed in the account asked for.
final class SignIn {
    let email: String
    let client: OAuthClient
    let verifier: String
    let state = UUID().uuidString
    let queue = DispatchQueue(label: "pim-bridge.gmail.sign-in")
    var listener: NWListener?
    var finished = false
    var url: URL?

    init(email: String, client: OAuthClient) {
        self.email = email
        self.client = client
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        verifier = base64url(Data(bytes))
    }

    var redirect: String { "http://127.0.0.1:\(listener?.port?.rawValue ?? 0)" }

    /// Starts listening and opens the browser; returns the sign-in URL.
    func start() throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): self?.finish("Sign-in listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.accept($0) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ToolError(message: "Couldn't listen for the sign-in")
        }
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            .init(name: "client_id", value: client.id),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: gmailScope),
            .init(name: "code_challenge", value: base64url(Data(SHA256.hash(data: Data(verifier.utf8))))),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "login_hint", value: email),
            // A refresh token every time, even if this client was allowed before.
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
        ]
        let url = components.url!
        self.url = url
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        queue.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish("Sign-in timed out") }
        return url
    }

    func cancel() { queue.async { self.finish(nil) } }

    /// On `queue`. `problem` nil means signed in (or cancelled).
    func finish(_ problem: String?) {
        guard !finished else { return }
        finished = true
        listener?.cancel()
        locked {
            if signIns[email] === self { signIns[email] = nil }
            if let problem = problem { accountProblems[email] = problem }
        }
        if let problem = problem { log("gmail: sign-in for \(email) failed: \(problem)") }
    }

    func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self = self else { return connection.cancel() }
            let line = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard !self.finished, parts.count >= 2, parts[0] == "GET",
                  let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
                  components.path == "/" || components.path.isEmpty,
                  let items = components.queryItems, items.contains(where: { $0.name == "code" || $0.name == "error" })
            else { return self.respond(connection, "404 Not Found", nil) }
            let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            if let error = q["error"] {
                self.respond(connection, "200 OK", ("Sign-in cancelled", "Google said: \(error). You can close this tab."))
                return self.finish(error == "access_denied" ? "Sign-in was cancelled in the browser" : "Google sign-in failed: \(error)")
            }
            guard q["state"] == self.state, let code = q["code"] else {
                return self.respond(connection, "400 Bad Request", ("Sign-in failed", "The reply didn't match this sign-in."))
            }
            let problem = self.exchange(code)
            self.respond(connection, "200 OK", problem.map { ("Sign-in failed", $0) }
                         ?? ("Signed in", "PIM Bridge can now read Gmail for \(self.email). You can close this tab."))
            self.finish(problem)
        }
    }

    /// Trades the code for tokens and saves the refresh token; returns what went wrong, if anything.
    func exchange(_ code: String) -> String? {
        do {
            let reply = try tokenRequest([("client_id", client.id), ("client_secret", client.secret), ("code", code),
                                          ("code_verifier", verifier), ("redirect_uri", redirect),
                                          ("grant_type", "authorization_code")])
            guard let access = reply["access_token"] as? String else {
                return "Google refused the sign-in: \(reply["error_description"] ?? reply["error"] ?? "no reason given")"
            }
            guard let refresh = reply["refresh_token"] as? String else { return "Google didn't return a refresh token" }
            // Google's consent screen lets each scope be unticked.
            guard (reply["scope"] as? String ?? "").split(separator: " ").contains(Substring(gmailScope)) else {
                return "Gmail access wasn't allowed on Google's consent screen; sign in again and tick it"
            }
            var request = URLRequest(url: URL(string: gmailAPI + "/profile")!)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            let got = (try send(request).json["emailAddress"] as? String ?? "").lowercased()
            guard got == email else {
                return got.isEmpty ? "Couldn't confirm which account signed in"
                    : "Signed in as \(got), not \(email); sign in again and pick \(email)"
            }
            try TokenStore.save(email, refresh)
            let lifetime = (reply["expires_in"] as? Double) ?? 3600
            locked {
                refreshTokens[email] = refresh
                accessTokens[email] = (access, Date().addingTimeInterval(lifetime - 60))
                accountProblems[email] = nil
            }
            log("gmail: \(email) signed in")
            return nil
        } catch let error as ToolError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    func respond(_ connection: NWConnection, _ status: String, _ page: (String, String)?) {
        let escape = { (s: String) in s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        let body = page.map { title, text in
            """
            <!doctype html><meta charset="utf-8"><title>\(escape(title))</title>
            <body style="font: 15px -apple-system, system-ui, sans-serif; max-width: 32em; margin: 15vh auto; padding: 0 16px">
            <h2>\(escape(title))</h2><p>\(escape(text))</p></body>
            """
        } ?? ""
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}

var signIns: [String: SignIn] = [:]

func base64url(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func fromBase64url(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    s += String(repeating: "=", count: (4 - s.count % 4) % 4)
    return Data(base64Encoded: s)
}

// MARK: - Messages

func header(_ payload: [String: Any]?, _ name: String) -> String? {
    (payload?["headers"] as? [[String: Any]])?
        .first(where: { ($0["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame })?["value"] as? String
}

func messageDate(_ message: [String: Any]) -> String? {
    guard let ms = Double(message["internalDate"] as? String ?? "") else { return nil }
    return timestamp(Date(timeIntervalSince1970: ms / 1000))
}

func webURL(_ account: GmailAccount, thread: String) -> String {
    "https://mail.google.com/mail/u/\(account.email)/#all/\(thread)"
}

/// The fields every listing shows, from a message in any format.
func summary(_ account: GmailAccount, _ message: [String: Any]) -> [String: Any] {
    let payload = message["payload"] as? [String: Any]
    let labels = message["labelIds"] as? [String] ?? []
    let thread = message["threadId"] as? String ?? ""
    var out: [String: Any] = [
        "id": message["id"] as? String ?? "", "thread_id": thread,
        "from": header(payload, "From") ?? "", "to": header(payload, "To") ?? "",
        "subject": header(payload, "Subject") ?? "", "snippet": decodeEntities(message["snippet"] as? String ?? ""),
        "labels": labels, "unread": labels.contains("UNREAD"), "url": webURL(account, thread: thread),
    ]
    if let cc = header(payload, "Cc") { out["cc"] = cc }
    if let date = messageDate(message) { out["date"] = date }
    return out
}

/// Header-only copies of messages, so polling every 30 s doesn't refetch the same 100
/// messages each time. Five minutes keeps labels (unread, inbox) close to current.
var metadataCache: [String: (fetched: Date, message: [String: Any])] = [:]

func metadata(_ account: GmailAccount, _ id: String) throws -> [String: Any] {
    let key = account.email + "/" + id
    if let hit = locked({ metadataCache[key] }), hit.fetched.timeIntervalSinceNow > -300 { return hit.message }
    let message = try gmail(account, "/messages/\(id)", query: [URLQueryItem(name: "format", value: "metadata")]
        + ["From", "To", "Cc", "Subject", "Date"].map { URLQueryItem(name: "metadataHeaders", value: $0) })
    locked {
        if metadataCache.count > 5000 { metadataCache = metadataCache.filter { $0.value.fetched.timeIntervalSinceNow > -300 } }
        metadataCache[key] = (Date(), message)
    }
    return message
}

/// Message metadata for many ids; ones Gmail no longer has are left out.
func metadata(_ account: GmailAccount, _ ids: [String]) throws -> [[String: Any]] {
    try concurrently(ids) { id -> [String: Any]? in
        do { return try metadata(account, id) } catch let error as GmailAPIError where error.status == 404 { return nil }
    }.compactMap { $0 }
}

/// Bodies and attachments from a message's MIME tree.
struct Content {
    var text: String?
    var html: String?
    var attachments: [[String: Any]] = []
}

func content(_ payload: [String: Any]?) -> Content {
    var found = Content()
    func walk(_ part: [String: Any]) {
        let mime = (part["mimeType"] as? String ?? "").lowercased()
        let filename = part["filename"] as? String ?? ""
        let body = part["body"] as? [String: Any] ?? [:]
        if !mime.hasPrefix("multipart/") && (!filename.isEmpty || body["attachmentId"] != nil) {
            found.attachments.append(["filename": filename, "mime_type": mime, "size": body["size"] as? Int ?? 0])
            return
        }
        let decoded = (body["data"] as? String).flatMap(fromBase64url).map { String(decoding: $0, as: UTF8.self) }
        if mime == "text/plain", found.text == nil { found.text = decoded }
        if mime == "text/html", found.html == nil { found.html = decoded }
        for child in part["parts"] as? [[String: Any]] ?? [] { walk(child) }
    }
    if let payload = payload { walk(payload) }
    return found
}

/// A whole message: the summary plus its text (and HTML when asked for).
func fullMessage(_ account: GmailAccount, _ message: [String: Any], html: Bool) -> [String: Any] {
    var out = summary(account, message)
    let payload = message["payload"] as? [String: Any]
    let body = content(payload)
    var text = body.text ?? body.html.map(htmlToText) ?? ""
    if text.count > 100_000 { text = String(text.prefix(100_000)) + "\n[… cut at 100,000 characters]" }
    out["text"] = text
    if html, let h = body.html { out["html"] = h }
    if !body.attachments.isEmpty { out["attachments"] = body.attachments }
    for name in ["Bcc", "Reply-To", "Message-ID"] {
        if let value = header(payload, name) { out[name.lowercased().replacingOccurrences(of: "-", with: "_")] = value }
    }
    out.removeValue(forKey: "snippet")
    return out
}

// MARK: - Text

let entityNames = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "#39": "'"]

func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    let pattern = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
    var out = text
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        let name = (text as NSString).substring(with: match.range(at: 1))
        var replacement = entityNames[name.lowercased()]
        if replacement == nil, name.hasPrefix("#") {
            let number = name.hasPrefix("#x") || name.hasPrefix("#X") ? UInt32(name.dropFirst(2), radix: 16) : UInt32(name.dropFirst())
            replacement = number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if let r = replacement { out = (out as NSString).replacingCharacters(in: match.range, with: r) }
    }
    return out
}

func replace(_ text: String, _ pattern: String, _ template: String) -> String {
    let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
}

/// A readable plain-text version of an email's HTML: paragraphs, line breaks and bullets kept.
func htmlToText(_ html: String) -> String {
    var s = replace(html, "<(head|style|script)\\b.*?</\\1\\s*>", "")
    s = replace(s, "<!--.*?-->", "")
    s = replace(s, "\\s+", " ")
    s = replace(s, "<br\\s*/?>", "\n")
    s = replace(s, "<li\\b[^>]*>", "\n- ")
    s = replace(s, "</?(p|div|h[1-6]|ul|ol|tr|table|blockquote)\\b[^>]*>", "\n\n")
    s = replace(s, "<[^>]+>", "")
    s = decodeEntities(s)
    let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    return replace(lines.joined(separator: "\n"), "\n{3,}", "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

// MARK: - Composing

/// Addresses from an array or a comma-separated string, splitting only outside quotes and <>.
func addresses(_ value: Any?) -> [String] {
    if let list = value as? [Any] { return list.compactMap { $0 as? String }.flatMap(addresses) }
    guard let text = value as? String else { return [] }
    var out: [String] = []
    var current = ""
    var quoted = false
    var angle = false
    for ch in text {
        if ch == "\"" { quoted.toggle() }
        if ch == "<" && !quoted { angle = true }
        if ch == ">" && !quoted { angle = false }
        if ch == "," && !quoted && !angle {
            out.append(current)
            current = ""
        } else {
            current.append(ch)
        }
    }
    out.append(current)
    return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
}

/// RFC 2047 encoded words for non-ASCII header text, each under the 75-character limit.
func encodeWords(_ text: String) -> String {
    guard !text.allSatisfy(\.isASCII) else { return text }
    var words: [String] = []
    var chunk = ""
    for ch in text {
        if (chunk + String(ch)).utf8.count > 45 {
            words.append(chunk)
            chunk = ""
        }
        chunk.append(ch)
    }
    words.append(chunk)
    return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
}

/// "Name <addr>" with the name encoded when it isn't ASCII.
func encodeAddress(_ address: String) -> String {
    guard !address.allSatisfy(\.isASCII), let open = address.lastIndex(of: "<") else { return address }
    let name = address[..<open].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    return encodeWords(name) + " " + address[open...]
}

func wrapBase64(_ data: Data) -> String {
    data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
}

/// A draft's MIME message: plain text alone, or HTML with a plain-text alternative.
func mimeMessage(headers: [(String, String)], text: String, html: String?) -> String {
    var lines = headers.filter { !$0.1.isEmpty }.map { name, value -> String in
        let encoded = ["To", "Cc", "Bcc", "From"].contains(name) ? addresses(value).map(encodeAddress).joined(separator: ",\r\n ")
            : name == "References" ? value.split(separator: " ").joined(separator: "\r\n ") : encodeWords(value)
        return "\(name): \(encoded)"
    }
    lines.append("MIME-Version: 1.0")
    let plain = "Content-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + wrapBase64(Data(text.utf8))
    guard let html = html else { return (lines + [plain]).joined(separator: "\r\n") }
    let boundary = "pim-bridge-" + UUID().uuidString
    lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
    let htmlPart = "Content-Type: text/html; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n" + wrapBase64(Data(html.utf8))
    return lines.joined(separator: "\r\n") + "\r\n\r\n--\(boundary)\r\n\(plain)\r\n--\(boundary)\r\n\(htmlPart)\r\n--\(boundary)--\r\n"
}

/// The body to save: `html` (with a generated plain-text copy) or `text`, else `current`.
func draftBody(_ args: [String: Any], current: Content? = nil) -> (text: String, html: String?) {
    if let html = args["html"] as? String { return (htmlToText(html), html) }
    if let text = args["text"] as? String { return (text, nil) }
    if let html = current?.html { return (current?.text ?? htmlToText(html), html) }
    return (current?.text ?? "", nil)
}

func addressField(_ args: [String: Any], _ key: String, current: String?) -> String {
    args[key] == nil ? current ?? "" : addresses(args[key]).joined(separator: ", ")
}

func describeDraft(_ account: GmailAccount, _ draft: [String: Any], bodies: Bool) -> [String: Any] {
    let message = draft["message"] as? [String: Any] ?? [:]
    let payload = message["payload"] as? [String: Any]
    var out = summary(account, message)
    out["draft_id"] = draft["id"] as? String ?? ""
    out["message_id"] = out.removeValue(forKey: "id")
    out["url"] = "https://mail.google.com/mail/u/\(account.email)/#drafts?compose=\(message["id"] as? String ?? "")"
    if let bcc = header(payload, "Bcc") { out["bcc"] = bcc }
    if let inReplyTo = header(payload, "In-Reply-To") { out["in_reply_to"] = inReplyTo }
    if bodies {
        let body = content(payload)
        out["text"] = body.text ?? body.html.map(htmlToText) ?? ""
        if let html = body.html { out["html"] = html }
        if !body.attachments.isEmpty { out["attachments"] = body.attachments }
        out.removeValue(forKey: "snippet")
    }
    return out
}

// MARK: - Trash

func senderAddress(_ from: String) -> String {
    guard let open = from.lastIndex(of: "<"), let close = from.lastIndex(of: ">"), open < close else {
        return from.trimmingCharacters(in: .whitespaces).lowercased()
    }
    return String(from[from.index(after: open)..<close]).lowercased()
}

/// Text from an email made safe for the Touch ID prompt: one line, and no control or
/// bidirectional-override characters that could make the prompt read differently.
func promptSafe(_ text: String) -> String {
    let scalars = text.unicodeScalars.map { scalar -> Unicode.Scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator: return " "
        default: return scalar
        }
    }
    return String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: "\"", with: "'")
        .trimmingCharacters(in: .whitespaces)
}

/// A subject as it appears in the Touch ID prompt: short, in quotes.
func promptSubject(_ subject: String) -> String {
    let flat = promptSafe(subject)
    if flat.isEmpty { return "(no subject)" }
    return "\"" + (flat.count > 40 ? flat.prefix(39) + "…" : flat) + "\""
}

/// What the Touch ID prompt says, after "PIM Bridge is trying to".
/// With `threads`, `messages` are thread summaries, and the prompt counts conversations
/// and the emails in them.
func trashReason(_ account: GmailAccount, _ messages: [[String: Any]], threads: Bool = false) -> String {
    let count = messages.count
    var what = threads ? (count == 1 ? "1 conversation" : "\(count) conversations") : (count == 1 ? "1 email" : "\(count) emails")
    if threads {
        let emails = messages.reduce(0) { $0 + ($1["messages"] as? Int ?? 1) }
        if emails != count { what += " (\(emails) emails)" }
    }
    let head = "move \(what) to Trash in \(account.email)"
    if count <= 3 {
        return head + ": " + messages.map { promptSubject($0["subject"] as? String ?? "") }.joined(separator: ", ")
    }
    var bySender: [String: Int] = [:]
    for m in messages { bySender[promptSafe(senderAddress(m["from"] as? String ?? "")), default: 0] += 1 }
    let top = bySender.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).filter { $0.value > 1 }
    if top.isEmpty { return head + " (from \(bySender.count) different senders)" }
    var parts = top.map { "\($0.value) from \($0.key)" }
    let rest = count - top.reduce(0) { $0 + $1.value }
    if rest > 0 { parts.append(rest == 1 ? "1 other" : "\(rest) others") }
    return head + " (" + parts.joined(separator: ", ") + ")"
}

/// Touch ID only: no "Enter Password" button, and no fallback when there's no sensor.
func confirmWithTouchID(_ reason: String) throws {
    let context = LAContext()
    context.localizedFallbackTitle = ""
    var unavailable: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &unavailable) else {
        throw ToolError(message: "Nothing moved to Trash: Touch ID isn't available on the Mac right now "
                        + "(\(unavailable?.localizedDescription ?? "no sensor")), and trash needs it.")
    }
    let done = DispatchSemaphore(value: 0)
    var allowed = false
    var failure: Error?
    context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { ok, error in
        allowed = ok
        failure = error
        done.signal()
    }
    if done.wait(timeout: .now() + 60) == .timedOut {
        context.invalidate()
        throw ToolError(message: "Nothing moved to Trash: nobody answered the Touch ID prompt.")
    }
    guard allowed else {
        throw ToolError(message: "Nothing moved to Trash: Touch ID didn't confirm it (\(failure?.localizedDescription ?? "cancelled")).")
    }
}

let trashLogLock = NSLock()

func appendTrashLog(_ entries: [[String: Any]]) {
    guard !entries.isEmpty else { return }
    trashLogLock.lock()
    defer { trashLogLock.unlock() }
    let lines = readTrashLog() + entries
    let data = lines.compactMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]) }
        .map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
    do { try writePrivate(Data(data.utf8), to: trashLogURL) } catch { log("gmail: can't write the trash log: \(error)") }
}

/// Log times are UTC ("…Z"), so they sort as text across daylight-saving changes.
func utcTimestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// The last 90 days of the log, oldest first.
func readTrashLog() -> [[String: Any]] {
    let cutoff = utcTimestamp(Date().addingTimeInterval(-trashLogDays * 86_400))
    let text = (try? String(contentsOf: trashLogURL, encoding: .utf8)) ?? ""
    return text.split(separator: "\n").compactMap { line -> [String: Any]? in
        guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let time = entry["time"] as? String, time >= cutoff else { return nil }
        return entry
    }
}

func moveMail(_ args: [String: Any], trash: Bool) throws -> Any {
    let account = try resolveAccount(args)
    let ids = try (args["ids"] as? [Any] ?? [args["ids"] as Any]).map { try gmailID($0, "ids: the message ids to move") }
    guard !ids.isEmpty else { throw ToolError(message: "Pass ids: the message ids to move") }
    guard ids.count <= 500 else { throw ToolError(message: "At most 500 messages at a time") }
    let messages = try concurrently(Array(Set(ids))) { id -> [String: Any] in
        do { return summary(account, try metadata(account, id)) } catch let error as GmailAPIError where error.status == 404 {
            throw ToolError(message: "No message \(id) in \(account.email)")
        }
    }
    let caller = currentCaller
    if trash && caller != .menuBar { try confirmWithTouchID(trashReason(account, messages)) }
    // Gmail's trash drops the INBOX label and untrash doesn't restore it, so untrash puts it
    // back when the log says the message was in the inbox (entries from before that field: yes).
    var backToInbox: Set<String> = []
    if !trash {
        trashLogLock.lock()
        for entry in readTrashLog() where entry["account"] as? String == account.email && entry["action"] as? String == "trash" {
            guard let id = entry["id"] as? String else { continue }
            if entry["inbox"] as? Bool ?? true { backToInbox.insert(id) } else { backToInbox.remove(id) }
        }
        trashLogLock.unlock()
    }
    let outcomes = try concurrently(messages) { m -> (id: String, error: String?) in
        let id = m["id"] as? String ?? ""
        do {
            _ = try gmail(account, "/messages/\(id)/\(trash ? "trash" : "untrash")", method: "POST")
            if backToInbox.contains(id) {
                _ = try gmail(account, "/messages/\(id)/modify", method: "POST", body: ["addLabelIds": ["INBOX"]])
            }
            locked { metadataCache[account.email + "/" + id] = nil }
            return (id, nil)
        } catch let error as GmailAPIError {
            return (id, error.message)
        }
    }
    var done: [[String: Any]] = []
    var failed: [[String: Any]] = []
    var log: [[String: Any]] = []
    for (m, outcome) in zip(messages, outcomes) {
        guard outcome.error == nil else {
            failed.append(["id": outcome.id, "error": outcome.error!])
            continue
        }
        var row: [String: Any] = ["id": outcome.id, "from": m["from"] ?? "", "subject": m["subject"] ?? ""]
        if !trash { row["inbox"] = backToInbox.contains(outcome.id) }
        done.append(row)
        var entry: [String: Any] = ["time": utcTimestamp(Date()), "action": trash ? "trash" : "untrash", "account": account.email,
                                    "id": outcome.id, "from": m["from"] ?? "", "subject": m["subject"] ?? "", "caller": caller.rawValue]
        if trash { entry["inbox"] = (m["labels"] as? [String] ?? []).contains("INBOX") }
        log.append(entry)
    }
    appendTrashLog(log)
    return [trash ? "trashed" : "untrashed": done, "failed": failed]
}

/// A thread for the prompt and the log: the first message's subject, the newest one's
/// sender, how many messages, and whether any is in the inbox.
func threadSummary(_ account: GmailAccount, _ id: String) throws -> [String: Any] {
    let thread = try gmail(account, "/threads/\(id)", query: [URLQueryItem(name: "format", value: "metadata")]
        + ["From", "Subject"].map { URLQueryItem(name: "metadataHeaders", value: $0) })
    let messages = thread["messages"] as? [[String: Any]] ?? []
    return ["thread_id": id, "messages": messages.count,
            "subject": header(messages.first?["payload"] as? [String: Any], "Subject") ?? "",
            "from": header(messages.last?["payload"] as? [String: Any], "From") ?? "",
            "inbox": messages.contains { ($0["labelIds"] as? [String] ?? []).contains("INBOX") },
            "message_ids": messages.compactMap { $0["id"] as? String }]
}

/// Whole threads, like Gmail's own Trash button: the same rules as `moveMail`.
func moveThreads(_ args: [String: Any], trash: Bool) throws -> Any {
    let account = try resolveAccount(args)
    let ids = try (args["thread_ids"] as? [Any] ?? [args["thread_ids"] as Any])
        .map { try gmailID($0, "thread_ids: the thread ids to move") }
    guard !ids.isEmpty else { throw ToolError(message: "Pass thread_ids: the thread ids to move") }
    guard ids.count <= 500 else { throw ToolError(message: "At most 500 threads at a time") }
    let threads = try concurrently(Array(Set(ids))) { id -> [String: Any] in
        do { return try threadSummary(account, id) } catch let error as GmailAPIError where error.status == 404 {
            throw ToolError(message: "No thread \(id) in \(account.email)")
        }
    }
    let caller = currentCaller
    if trash && caller != .menuBar { try confirmWithTouchID(trashReason(account, threads, threads: true)) }
    var backToInbox: Set<String> = []
    if !trash {
        trashLogLock.lock()
        for entry in readTrashLog() where entry["account"] as? String == account.email && entry["action"] as? String == "trash" {
            guard let id = entry["thread_id"] as? String else { continue }
            if entry["inbox"] as? Bool ?? false { backToInbox.insert(id) } else { backToInbox.remove(id) }
        }
        trashLogLock.unlock()
    }
    let outcomes = try concurrently(threads) { t -> String? in
        let id = t["thread_id"] as? String ?? ""
        do {
            _ = try gmail(account, "/threads/\(id)/\(trash ? "trash" : "untrash")", method: "POST")
            if backToInbox.contains(id) {
                _ = try gmail(account, "/threads/\(id)/modify", method: "POST", body: ["addLabelIds": ["INBOX"]])
            }
            locked { for m in t["message_ids"] as? [String] ?? [] { metadataCache[account.email + "/" + m] = nil } }
            return nil
        } catch let error as GmailAPIError {
            return error.message
        }
    }
    var done: [[String: Any]] = []
    var failed: [[String: Any]] = []
    var log: [[String: Any]] = []
    for (t, error) in zip(threads, outcomes) {
        let id = t["thread_id"] as? String ?? ""
        if let error = error {
            failed.append(["thread_id": id, "error": error])
            continue
        }
        var row: [String: Any] = ["thread_id": id, "from": t["from"] ?? "", "subject": t["subject"] ?? "", "messages": t["messages"] ?? 0]
        if !trash { row["inbox"] = backToInbox.contains(id) }
        done.append(row)
        var entry: [String: Any] = ["time": utcTimestamp(Date()), "action": trash ? "trash" : "untrash", "account": account.email,
                                    "thread_id": id, "messages": t["messages"] ?? 0, "from": t["from"] ?? "",
                                    "subject": t["subject"] ?? "", "caller": caller.rawValue]
        if trash { entry["inbox"] = t["inbox"] ?? false }
        log.append(entry)
    }
    appendTrashLog(log)
    return [trash ? "trashed" : "untrashed": done, "failed": failed]
}

// MARK: - Tools

func listAccounts(_ args: [String: Any]) throws -> Any {
    let accounts = locked { gmailAccounts }
    var out: [String: Any] = ["accounts": accounts.map { account -> [String: Any] in
        let (signingIn, problem) = locked { (signIns[account.email] != nil, accountProblems[account.email]) }
        let status = signingIn ? "signing_in" : refreshToken(account.email) != nil ? "signed_in" : "needs_sign_in"
        var row: [String: Any] = ["name": account.name, "email": account.email, "status": status]
        if let problem = problem, status != "signed_in" { row["problem"] = problem }
        return row
    }]
    if loadClient() == nil { out["problem"] = "Gmail isn't set up: no OAuth client at \(gmailClientURL.path)" }
    return out
}

func signIn(_ args: [String: Any]) throws -> Any {
    guard let email = (args["email"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased(),
          email.contains("@") else { throw ToolError(message: "Pass email: the Google account to sign in") }
    let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
    let client = try requireClient()
    try locked {
        if let i = gmailAccounts.firstIndex(where: { $0.email == email }) {
            if !name.isEmpty && gmailAccounts[i].name != name { gmailAccounts[i].name = name; try saveAccounts() }
        } else {
            guard !name.isEmpty else { throw ToolError(message: "Pass name too for a new account (e.g. \"Fenderton\")") }
            if gmailAccounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                throw ToolError(message: "Another account is already called \(name)")
            }
            gmailAccounts.append(GmailAccount(name: name, email: email))
            try saveAccounts()
        }
    }
    let flow = SignIn(email: email, client: client)
    let previous = locked { () -> SignIn? in
        let old = signIns[email]
        signIns[email] = flow
        accountProblems[email] = nil
        return old
    }
    previous?.cancel()
    do {
        let url = try flow.start()
        log("gmail: sign-in started for \(email)")
        return ["email": email, "status": "signing_in", "url": url.absoluteString,
                "next": "Finish in the browser window that opened (or open url); accounts shows signed_in when done."]
    } catch {
        locked { if signIns[email] === flow { signIns[email] = nil } }
        throw error
    }
}

func signOut(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let email = account.email
    locked { signIns[email] }?.cancel()
    if let refresh = refreshToken(email) {
        // Tell Google too, so the token is dead even if a copy exists somewhere.
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([("token", refresh)])
        if (try? send(request))?.status != 200 { log("gmail: couldn't revoke \(email)'s token at Google; deleted it here") }
    }
    forgetTokens(email)
    let remove = args["remove"] as? Bool ?? false
    try locked {
        accountProblems[email] = nil
        if remove { gmailAccounts.removeAll { $0.email == email }; try saveAccounts() }
    }
    log("gmail: \(email) signed out\(remove ? " and removed" : "")")
    return ["signed_out": email, "removed": remove]
}

func clamp(_ value: Any?, _ fallback: Int, _ high: Int) -> Int { max(1, min(high, value as? Int ?? fallback)) }

func searchMail(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let query = args["query"] as? String ?? ""
    let list = try gmail(account, "/messages", query: [URLQueryItem(name: "q", value: query),
                                                       URLQueryItem(name: "maxResults", value: String(clamp(args["max"], 25, 500)))])
    let ids = (list["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    return ["account": account.email, "query": query, "estimated_total": list["resultSizeEstimate"] as? Int ?? ids.count,
            "messages": try metadata(account, ids).map { summary(account, $0) }]
}

func readMessage(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let id = try gmailID(args["id"], "id: a message id from search")
    return fullMessage(account, try gmail(account, "/messages/\(id)", query: [URLQueryItem(name: "format", value: "full")]),
                       html: args["html"] as? Bool ?? false)
}

func readThread(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let id = try gmailID(args["thread_id"], "thread_id, from search")
    let thread = try gmail(account, "/threads/\(id)", query: [URLQueryItem(name: "format", value: "full")])
    let html = args["html"] as? Bool ?? false
    return ["thread_id": id, "url": webURL(account, thread: id),
            "messages": (thread["messages"] as? [[String: Any]] ?? []).map { fullMessage(account, $0, html: html) }]
}

func listDrafts(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    var query = [URLQueryItem(name: "maxResults", value: String(clamp(args["max"], 25, 500)))]
    if let q = args["query"] as? String, !q.isEmpty { query.append(URLQueryItem(name: "q", value: q)) }
    let list = try gmail(account, "/drafts", query: query)
    let drafts = list["drafts"] as? [[String: Any]] ?? []
    let rows = try concurrently(drafts) { draft -> [String: Any]? in
        guard let id = try? gmailID(draft["id"], "draft id") else { return nil }
        do {
            return describeDraft(account, try gmail(account, "/drafts/\(id)", query: [URLQueryItem(name: "format", value: "metadata")]),
                                 bodies: false)
        } catch let error as GmailAPIError where error.status == 404 { return nil }
    }
    return ["account": account.email, "drafts": rows.compactMap { $0 }]
}

func getDraft(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let id = try gmailID(args["draft_id"], "draft_id, from list_drafts")
    return describeDraft(account, try gmail(account, "/drafts/\(id)", query: [URLQueryItem(name: "format", value: "full")]), bodies: true)
}

func createDraft(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    var headers: [(String, String)] = []
    var subject = args["subject"] as? String ?? ""
    var to = addresses(args["to"]).joined(separator: ", ")
    var threadID: String?
    if let raw = args["reply_to_message_id"] as? String, !raw.isEmpty {
        let replyTo = try gmailID(raw, "reply_to_message_id")
        let original = try gmail(account, "/messages/\(replyTo)", query: [URLQueryItem(name: "format", value: "metadata")]
            + ["From", "Reply-To", "Subject", "Message-ID", "References"].map { URLQueryItem(name: "metadataHeaders", value: $0) })
        let payload = original["payload"] as? [String: Any]
        threadID = original["threadId"] as? String
        if let messageID = header(payload, "Message-ID") {
            headers.append(("In-Reply-To", messageID))
            headers.append(("References", [header(payload, "References"), messageID].compactMap { $0 }.joined(separator: " ")))
        }
        if args["subject"] == nil {
            let old = header(payload, "Subject") ?? ""
            subject = old.lowercased().hasPrefix("re:") ? old : "Re: " + old
        }
        if args["to"] == nil { to = header(payload, "Reply-To") ?? header(payload, "From") ?? "" }
    }
    let body = draftBody(args)
    headers = [("To", to), ("Cc", addressField(args, "cc", current: nil)), ("Bcc", addressField(args, "bcc", current: nil)),
               ("Subject", subject)] + headers
    var message: [String: Any] = ["raw": base64url(Data(mimeMessage(headers: headers, text: body.text, html: body.html).utf8))]
    if let thread = threadID { message["threadId"] = thread }
    let created = try gmail(account, "/drafts", method: "POST", body: ["message": message])
    guard let id = created["id"] as? String else { throw ToolError(message: "Gmail didn't return the new draft") }
    log("gmail: created draft \(id) in \(account.email)")
    return describeDraft(account, try gmail(account, "/drafts/\(id)", query: [URLQueryItem(name: "format", value: "full")]), bodies: true)
}

func updateDraft(_ args: [String: Any]) throws -> Any {
    let account = try resolveAccount(args)
    let id = try gmailID(args["draft_id"], "draft_id, from list_drafts")
    let draft = try gmail(account, "/drafts/\(id)", query: [URLQueryItem(name: "format", value: "full")])
    let message = draft["message"] as? [String: Any] ?? [:]
    let payload = message["payload"] as? [String: Any]
    let current = content(payload)
    guard current.attachments.isEmpty else {
        let names = current.attachments.map { $0["filename"] as? String ?? "" }.map { $0.isEmpty ? "an inline image" : $0 }
        throw ToolError(message: "Not changed: this draft has attachments (\(names.joined(separator: ", "))), which "
                        + "rewriting it would drop. Edit it in Gmail instead.")
    }
    let body = draftBody(args, current: current)
    let headers: [(String, String)] = [
        ("From", header(payload, "From") ?? ""),
        ("To", addressField(args, "to", current: header(payload, "To"))),
        ("Cc", addressField(args, "cc", current: header(payload, "Cc"))),
        ("Bcc", addressField(args, "bcc", current: header(payload, "Bcc"))),
        ("Subject", args["subject"] as? String ?? header(payload, "Subject") ?? ""),
        ("In-Reply-To", header(payload, "In-Reply-To") ?? ""),
        ("References", header(payload, "References") ?? ""),
    ]
    var replacement: [String: Any] = ["raw": base64url(Data(mimeMessage(headers: headers, text: body.text, html: body.html).utf8))]
    if let thread = message["threadId"] as? String { replacement["threadId"] = thread }
    _ = try gmail(account, "/drafts/\(id)", method: "PUT", body: ["id": id, "message": replacement])
    log("gmail: updated draft \(id) in \(account.email)")
    return describeDraft(account, try gmail(account, "/drafts/\(id)", query: [URLQueryItem(name: "format", value: "full")]), bodies: true)
}

func trashLog(_ args: [String: Any]) throws -> Any {
    let email = args["account"] == nil ? nil : try resolveAccount(args).email
    let since = utcTimestamp(Date().addingTimeInterval(-Double(clamp(args["days"], 30, Int(trashLogDays))) * 86_400))
    trashLogLock.lock()
    let entries = readTrashLog()
    trashLogLock.unlock()
    let matching = entries.filter { ($0["time"] as? String ?? "") >= since && (email == nil || $0["account"] as? String == email) }
    return ["entries": Array(matching.reversed().prefix(clamp(args["limit"], 100, 10_000)))]
}

/// For /health, which runs on the network queue: no keychain reads (they can prompt).
func gmailHealth() -> String {
    guard loadClient() != nil else { return "not set up" }
    return "\(locked { gmailAccounts.count }) accounts"
}

let accountProperty: [String: Any] = ["type": "string", "description": "Account email or name, from accounts"]
let recipientsProperty: [String: Any] = [
    "type": "array", "items": ["type": "string"],
    "description": "Addresses, e.g. [\"Thanh <thanh@example.com>\"]; [] clears",
]
let draftFields: [String: Any] = [
    "account": accountProperty,
    "to": recipientsProperty, "cc": recipientsProperty, "bcc": recipientsProperty,
    "subject": ["type": "string"],
    "html": ["type": "string", "description": "Body as HTML (<b>, <ul><li>, <p>…); a plain-text copy is generated. Gmail doesn't add Ian's signature."],
    "text": ["type": "string", "description": "Body as plain text, instead of html"],
]

let gmailTools: [Tool] = [
    Tool(name: "accounts",
         description: "The Gmail accounts PIM Bridge knows, with each one's sign-in status (signed_in, signing_in, needs_sign_in).",
         schema: schema([:]), readOnly: true, destructive: false, run: listAccounts),
    Tool(name: "sign_in",
         description: "Start Google sign-in for an account: opens the browser on the Mac and returns at once. Ian finishes it in the browser; poll accounts for the result. Adds the account if it's new (name required then).",
         schema: schema(["email": ["type": "string"], "name": ["type": "string", "description": "Short name, e.g. Fenderton"]],
                        required: ["email"]), readOnly: false, destructive: false, run: signIn),
    Tool(name: "sign_out",
         description: "Sign an account out for every client (MCP, CLI, MenuWidgets): revokes and deletes its token. remove: true also drops it from accounts.",
         schema: schema(["account": accountProperty, "remove": ["type": "boolean", "default": false]], required: ["account"]),
         readOnly: false, destructive: false, run: signOut),
    Tool(name: "search",
         description: "Search mail with Gmail's query syntax (from:, to:, subject:, is:unread, in:inbox, category:primary, newer_than:7d, has:attachment …), newest first. Returns headers and snippets; use read_message or read_thread for bodies.",
         schema: schema(["account": accountProperty, "query": ["type": "string", "description": "Gmail search; empty = all mail"],
                         "max": ["type": "integer", "default": 25, "minimum": 1, "maximum": 500]], required: ["account"]),
         readOnly: true, destructive: false, run: searchMail),
    Tool(name: "read_message",
         description: "One message with its body as text (and the HTML too with html: true), plus attachment names.",
         schema: schema(["account": accountProperty, "id": ["type": "string", "description": "Message id, from search"],
                         "html": ["type": "boolean", "default": false]], required: ["account", "id"]),
         readOnly: true, destructive: false, run: readMessage),
    Tool(name: "read_thread",
         description: "Every message in a thread, oldest first, with bodies as text.",
         schema: schema(["account": accountProperty, "thread_id": ["type": "string"], "html": ["type": "boolean", "default": false]],
                        required: ["account", "thread_id"]), readOnly: true, destructive: false, run: readThread),
    Tool(name: "list_drafts",
         description: "Drafts, newest first, optionally matching a Gmail search.",
         schema: schema(["account": accountProperty, "query": ["type": "string"],
                         "max": ["type": "integer", "default": 25, "minimum": 1, "maximum": 500]], required: ["account"]),
         readOnly: true, destructive: false, run: listDrafts),
    Tool(name: "get_draft",
         description: "One draft: recipients, subject, and the body as HTML and text.",
         schema: schema(["account": accountProperty, "draft_id": ["type": "string"]], required: ["account", "draft_id"]),
         readOnly: true, destructive: false, run: getDraft),
    Tool(name: "create_draft",
         description: "Create a draft for Ian to review and send himself (nothing here sends mail). With reply_to_message_id it joins that thread with the reply headers, and to and subject default to a reply.",
         schema: schema(draftFields.merging(["reply_to_message_id": ["type": "string", "description": "Message id this replies to"]]) { a, _ in a },
                        required: ["account"]), readOnly: false, destructive: false, run: createDraft),
    Tool(name: "update_draft",
         description: "Change a draft in place. Fields you don't pass keep their values; the thread and reply headers are kept. Passing html or text replaces the whole body, so start from get_draft's html. Refuses drafts with attachments. If the draft is open in Gmail, Gmail may save over the change: ask Ian to close it first.",
         schema: schema(draftFields.merging(["draft_id": ["type": "string"]]) { a, _ in a }, required: ["account", "draft_id"]),
         readOnly: false, destructive: false, run: updateDraft),
    Tool(name: "trash",
         description: "Move messages to Trash (Gmail deletes them for good after 30 days; untrash puts them back before then). Asks Ian for Touch ID on the Mac, with a prompt saying what will be moved; fails without it. Only trash what Ian asked for.",
         schema: schema(["account": accountProperty, "ids": ["type": "array", "items": ["type": "string"], "description": "Message ids"]],
                        required: ["account", "ids"]), readOnly: false, destructive: true, run: { try moveMail($0, trash: true) }),
    Tool(name: "untrash",
         description: "Move messages back out of Trash, and back into the inbox if they were trashed from it through PIM Bridge.",
         schema: schema(["account": accountProperty, "ids": ["type": "array", "items": ["type": "string"], "description": "Message ids"]],
                        required: ["account", "ids"]), readOnly: false, destructive: false, run: { try moveMail($0, trash: false) }),
    Tool(name: "trash_thread",
         description: "Move whole threads (every message in each conversation) to Trash, like Gmail's Trash button. Asks Ian for Touch ID on the Mac, with a prompt saying what will be moved; fails without it. Only trash what Ian asked for.",
         schema: schema(["account": accountProperty, "thread_ids": ["type": "array", "items": ["type": "string"], "description": "Thread ids, from search"]],
                        required: ["account", "thread_ids"]), readOnly: false, destructive: true, run: { try moveThreads($0, trash: true) }),
    Tool(name: "untrash_thread",
         description: "Move whole threads back out of Trash, and back into the inbox if they were trashed from it through PIM Bridge.",
         schema: schema(["account": accountProperty, "thread_ids": ["type": "array", "items": ["type": "string"], "description": "Thread ids"]],
                        required: ["account", "thread_ids"]), readOnly: false, destructive: false, run: { try moveThreads($0, trash: false) }),
    Tool(name: "trash_log",
         description: "Recent trash and untrash actions (kept 90 days), newest first: time, account, message id (or thread_id and message count for whole threads), sender, subject, and caller (menu bar or http).",
         schema: schema(["account": accountProperty, "days": ["type": "integer", "default": 30, "minimum": 1, "maximum": 90],
                         "limit": ["type": "integer", "default": 100, "minimum": 1]]),
         readOnly: true, destructive: false, run: trashLog),
]

let gmailInstructions = """
Gmail for Ian's Google Workspace accounts, through PIM Bridge on his Mac. accounts lists them; \
every other tool takes account as the email or the name. You can read, search, write and edit \
drafts, and move mail to and from Trash. Nothing here sends mail: drafts wait for Ian to review \
and send. Trash asks Ian for Touch ID on the Mac each time, so only trash what he asked for. \
Times are local (\(TimeZone.current.identifier)).
"""

let gmailServer = Server(
    name: "gmail", instructions: gmailInstructions, tools: gmailTools,
    accessProblem: { nil },  // per tool: accounts works before setup
    prepare: {}, queue: gmailQueue)

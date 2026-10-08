// PIM Bridge: serves Apple Reminders, Calendar and Contacts as three MCP servers
// over Streamable HTTP, to agents on this Mac.
//
//   http://127.0.0.1:8765/reminders/mcp
//   http://127.0.0.1:8765/calendar/mcp
//   http://127.0.0.1:8765/contacts/mcp
//
// It runs as a LaunchAgent so that macOS gives the Reminders, Calendars and
// Contacts permissions to this app alone. Otherwise every CLI an agent ran would
// borrow them from the terminal, and anything in a terminal would have them.
//
// The server is stateless: every POST carries one JSON-RPC message and gets one
// JSON response (or 202 for notifications). No sessions, no SSE.
//
// Access control:
//   1. It listens only on 127.0.0.1, so nothing off the Mac can reach it.
//   2. Every request, /health included, needs the bearer token (256 random bits) from
//      a 0600 file in ~/Library/Application Support/PIMBridge.
//   3. Requests with a browser Origin, or a Host that isn't loopback, are refused,
//      so a web page can't reach it through DNS rebinding.

import Contacts
import EventKit
import Foundation
import Network
import Security

let serverVersion = "2.0.0"
let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
let port = NWEndpoint.Port(rawValue: UInt16(environment["PB_PORT"] ?? "") ?? 8765)!
let netQueue = DispatchQueue(label: "pim-bridge.net")
let work = DispatchQueue(label: "pim-bridge.work")  // all EventKit and Contacts access is serialized here

let servers: [String: Server] = [
    "reminders": remindersServer,
    "calendar": calendarServer,
    "contacts": contactsServer,
]

// MARK: - Auth token

let tokenURL = supportDir.appendingPathComponent("token")

func loadOrCreateToken() -> String {
    if let saved = try? String(contentsOf: tokenURL, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
        return saved
    }
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        log("could not generate a token"); exit(1)
    }
    let token = bytes.map { String(format: "%02x", $0) }.joined()
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    FileManager.default.createFile(atPath: tokenURL.path, contents: Data(token.utf8),
                                   attributes: [.posixPermissions: 0o600])
    return token
}

let token = Data(loadOrCreateToken().utf8)

/// Constant-time, so response timing reveals nothing about the token.
func tokenMatches(_ header: String?) -> Bool {
    guard let header = header, header.hasPrefix("Bearer ") else { return false }
    let offered = Data(header.dropFirst("Bearer ".count).utf8)
    guard offered.count == token.count else { return false }
    return zip(offered, token).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

// MARK: - JSON-RPC

func rpcResult(_ id: Any, _ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }

func rpcError(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
}

func textResult(_ value: Any, isError: Bool = false) -> [String: Any] {
    let text: String
    if let string = value as? String {
        text = string
    } else {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        text = String(decoding: data, as: UTF8.self)
    }
    return ["content": [["type": "text", "text": text]], "isError": isError]
}

/// Returns nil for notifications (and stray responses), which get a bare 202.
func handle(_ server: Server, _ message: [String: Any]) -> [String: Any]? {
    guard let id = message["id"], let method = message["method"] as? String else { return nil }
    let params = message["params"] as? [String: Any] ?? [:]

    switch method {
    case "initialize":
        let requested = params["protocolVersion"] as? String ?? ""
        return rpcResult(id, [
            "protocolVersion": supportedProtocolVersions.contains(requested) ? requested : supportedProtocolVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": server.name, "version": serverVersion],
            "instructions": server.instructions,
        ] as [String: Any])
    case "ping":
        return rpcResult(id, [String: Any]())
    case "tools/list":
        return rpcResult(id, ["tools": server.tools.map { tool -> [String: Any] in
            [
                "name": tool.name,
                "description": tool.description,
                "inputSchema": tool.schema,
                "annotations": ["readOnlyHint": tool.readOnly, "destructiveHint": tool.destructive,
                                "idempotentHint": tool.readOnly, "openWorldHint": false],
            ]
        }])
    case "tools/call":
        guard let name = params["name"] as? String, let tool = server.tools.first(where: { $0.name == name }) else {
            return rpcError(id, -32602, "Unknown tool: \(params["name"] ?? "")")
        }
        if let problem = server.accessProblem() { return rpcResult(id, textResult(problem, isError: true)) }
        server.prepare()
        do {
            return rpcResult(id, textResult(try tool.run(params["arguments"] as? [String: Any] ?? [:])))
        } catch let error as ToolError {
            return rpcResult(id, textResult(error.message, isError: true))
        } catch {
            return rpcResult(id, textResult("\(error.localizedDescription)", isError: true))
        }
    default:
        return rpcError(id, -32601, "Method not found: \(method)")
    }
}

// MARK: - HTTP

struct Request {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

let loopbackHosts: Set = ["127.0.0.1", "localhost"]

final class Connection {
    let connection: NWConnection
    var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.start(queue: netQueue)
        // Nothing legitimate takes this long; don't let idle sockets pile up.
        netQueue.asyncAfter(deadline: .now() + 60) { self.connection.cancel() }
        receive()
    }

    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if let data = data { self.buffer.append(data) }
            if self.buffer.count > 4_000_000 { return self.respond(413, nil) }
            if let request = self.parse() { return self.route(request) }
            if isComplete || error != nil { return self.connection.cancel() }
            self.receive()
        }
    }

    func parse() -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        var lines = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            .components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ").map(String.init)
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let body = buffer.subdata(in: end.upperBound..<buffer.index(end.upperBound, offsetBy: length))
        let target = start.count > 1 ? start[1] : "/"
        return Request(method: start.first ?? "", path: String(target.split(separator: "?").first ?? ""),
                       headers: headers, body: body)
    }

    func route(_ request: Request) {
        // Browsers send Origin; MCP clients don't. With the Host check this blocks DNS rebinding.
        if let origin = request.headers["origin"], origin != "null" { return respond(403, nil) }
        let host = (request.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard loopbackHosts.contains(host.lowercased()) else { return respond(403, nil) }
        guard tokenMatches(request.headers["authorization"]) else {
            log("bad or missing token for \(request.path)")
            return respond(401, nil, extra: ["WWW-Authenticate": "Bearer"])
        }

        if request.path == "/health" {
            return respond(200, ["ok": true, "version": serverVersion, "reminders": accessStatus(.reminder),
                                 "calendar": accessStatus(.event), "contacts": contactsAccess()])
        }
        let parts = request.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[1] == "mcp", let server = servers[parts[0]] else { return respond(404, nil) }
        guard request.method == "POST" else { return respond(405, nil, extra: ["Allow": "POST"]) }
        if request.headers["transfer-encoding"] != nil { return respond(411, nil) }

        guard let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            return respond(400, rpcError(NSNull(), -32700, "Parse error: expected one JSON-RPC object"))
        }
        work.async {
            let reply = handle(server, message)
            netQueue.async { reply.map { self.respond(200, $0) } ?? self.respond(202, nil) }
        }
    }

    func respond(_ status: Int, _ json: Any?, extra: [String: String] = [:]) {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                       404: "Not Found", 405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large"]
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.withoutEscapingSlashes]) }
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "")\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        var out = Data((head + "\r\n").utf8)
        if let body = body { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in self.connection.cancel() })
    }
}

// MARK: - Main

log("pim-bridge \(serverVersion) starting on 127.0.0.1:\(port); reminders \(accessStatus(.reminder)), "
    + "calendar \(accessStatus(.event)), contacts \(contactsAccess())")

// One prompt at a time: each waits for the previous answer.
func requestAccess() {
    let next = DispatchSemaphore(value: 0)
    if accessStatus(.reminder) != "fullAccess" {
        store.requestFullAccessToReminders { granted, _ in log("reminders access granted=\(granted)"); next.signal() }
        next.wait()
    }
    if accessStatus(.event) != "fullAccess" {
        store.requestFullAccessToEvents { granted, _ in log("calendar access granted=\(granted)"); next.signal() }
        next.wait()
    }
    if contactsAccess() != "fullAccess" {
        contactStore.requestAccess(for: .contacts) { granted, _ in log("contacts access granted=\(granted)"); next.signal() }
        next.wait()
    }
}
work.async(execute: requestAccess)

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
parameters.allowLocalEndpointReuse = true
do {
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { Connection($0).start() }
    listener.stateUpdateHandler = { state in
        log("listener 127.0.0.1:\(port) \(state)")
        if case .failed = state { exit(1) }  // launchd restarts us
    }
    listener.start(queue: netQueue)
    // A real run loop, not dispatchMain: NSWorkspace needs it to launch and track Contacts.app.
    withExtendedLifetime(listener) { RunLoop.main.run() }
} catch {
    log("can't listen on 127.0.0.1:\(port): \(error)")
    exit(1)
}

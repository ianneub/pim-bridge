// Shared pieces: logging, tool plumbing, and reading dates and durations.

import Foundation

let environment = ProcessInfo.processInfo.environment

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}

struct ToolError: Error { let message: String }

let work = DispatchQueue(label: "pim-bridge.work")  // all EventKit and Contacts access is serialized here

/// Where the request being handled came from. Only MenuWidgets' socket is trusted to trash
/// mail without Touch ID; anything over HTTP could be any process on the Mac.
enum Caller: String {
    case http
    case menuBar = "menu bar"
}

let callerKey = "pim-bridge.caller"

/// The caller of the tool running on this thread (set by `handle`); HTTP unless proven otherwise.
var currentCaller: Caller { Thread.current.threadDictionary[callerKey] as? Caller ?? .http }

struct Tool {
    let name: String
    let description: String
    let schema: [String: Any]
    let readOnly: Bool
    let destructive: Bool
    let run: ([String: Any]) throws -> Any
}

/// One MCP server: a path on the bridge with its own tools and permission.
struct Server {
    let name: String
    let instructions: String
    let tools: [Tool]
    /// nil when access is granted, else what to tell the client.
    let accessProblem: () -> String?
    /// Run before each tool call, on `queue`.
    let prepare: () -> Void
    /// Where its tool calls run.
    var queue: DispatchQueue = work
}

func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
    ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
}

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/PIMBridge")

// MARK: - Dates

let posix = Locale(identifier: "en_US_POSIX")

func formatter(_ format: String, _ zone: TimeZone = .current) -> DateFormatter {
    let f = DateFormatter()
    f.locale = posix
    f.timeZone = zone
    f.dateFormat = format
    return f
}

func timestamp(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.timeZone = .current
    return f.string(from: date)
}

/// A moment someone typed, and whether they gave a time of day or just a date.
struct When {
    let date: Date
    let hasTime: Bool
}

let timeWords = try! NSRegularExpression(pattern:
    #"\b\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.|a|p)\b|\b\d{1,2}:\d{2}\b|\b(noon|midnight|now|tonight|morning|afternoon|evening)\b|\bat\s+\d"#,
    options: [.caseInsensitive])

let relativePart = try! NSRegularExpression(pattern:
    #"(\d+)\s*(weeks?|w|days?|d|hours?|hrs?|h|minutes?|mins?|m)(?![a-z])"#, options: [.caseInsensitive])

/// "1h 30m", "2 days", "in 45 minutes" as seconds, or nil if it isn't one.
func relativeSeconds(_ text: String) -> TimeInterval? {
    var rest = text.lowercased().trimmingCharacters(in: .whitespaces)
    if rest.hasPrefix("in ") { rest = String(rest.dropFirst(3)) }
    let range = NSRange(rest.startIndex..., in: rest)
    let matches = relativePart.matches(in: rest, range: range)
    guard !matches.isEmpty else { return nil }
    var covered = rest
    var total: TimeInterval = 0
    for m in matches.reversed() {
        let n = Double((rest as NSString).substring(with: m.range(at: 1)))!
        let unit = (rest as NSString).substring(with: m.range(at: 2))
        switch unit.first! {
        case "w": total += n * 604_800
        case "d": total += n * 86_400
        case "h": total += n * 3_600
        default: total += n * 60
        }
        covered = (covered as NSString).replacingCharacters(in: m.range, with: "")
    }
    let leftover = covered.replacingOccurrences(of: "and", with: "")
        .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
    return leftover.isEmpty ? total : nil
}

let dateDetector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)

/// ISO 8601 (YYYY-MM-DD, YYYY-MM-DDTHH:MM, with or without an offset) or plain
/// English: "tomorrow 3pm", "next fri at 9:30", "oct 12", "in 2 hours".
func parseWhen(_ raw: String) throws -> When {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = text.lowercased()
    let calendar = Calendar.current
    let now = Date()
    if text.isEmpty { throw ToolError(message: "empty date") }
    if let date = formatter("yyyy-MM-dd").date(from: text) { return When(date: date, hasTime: false) }
    for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm",
                   "yyyy-MM-dd HH:mm:ss"] {
        if let date = formatter(format).date(from: text) { return When(date: date, hasTime: true) }
    }
    let iso = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
        iso.formatOptions = options
        if let date = iso.date(from: text) { return When(date: date, hasTime: true) }
    }
    switch lower {
    case "now": return When(date: now, hasTime: true)
    case "today": return When(date: calendar.startOfDay(for: now), hasTime: false)
    case "tomorrow": return When(date: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!, hasTime: false)
    case "yesterday": return When(date: calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))!, hasTime: false)
    default: break
    }
    if let seconds = relativeSeconds(lower) {
        return When(date: now.addingTimeInterval(seconds), hasTime: true)
    }
    let range = NSRange(text.startIndex..., in: text)
    guard let match = dateDetector.firstMatch(in: text, range: range), let date = match.date else {
        throw ToolError(message: "Can't read the date \"\(raw)\"; try YYYY-MM-DD, YYYY-MM-DD HH:MM or \"tomorrow 3pm\"")
    }
    // Words outside what the detector understood mean it guessed at part of it.
    let outside = (text as NSString).replacingCharacters(in: match.range, with: "")
        .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty && !["at", "on", "the", "of", "this", "next", "in"].contains($0) }
    if !outside.isEmpty {
        throw ToolError(message: "Can't read \"\(outside.joined(separator: " "))\" in the date \"\(raw)\"")
    }
    let hasTime = timeWords.firstMatch(in: text, range: range) != nil
    return When(date: hasTime ? date : calendar.startOfDay(for: date), hasTime: hasTime)
}

/// "30m", "1h", "1h30m", "2d", or a bare number of minutes.
func parseDuration(_ raw: String) throws -> TimeInterval {
    let text = raw.trimmingCharacters(in: .whitespaces)
    if let minutes = Double(text) { return minutes * 60 }
    guard let seconds = relativeSeconds(text), seconds > 0 else {
        throw ToolError(message: "Can't read the duration \"\(raw)\" (try 30m, 1h, 1h30m, 2d)")
    }
    return seconds
}

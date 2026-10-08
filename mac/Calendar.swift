// Calendar events through EventKit: every account in System Settings → Internet
// Accounts that syncs calendars (iCloud, Google, Exchange...).
//
// Results are text, laid out the way the Omarchy `calendar` CLI printed them, with
// an 8-character id per event. EventKit has no short ids, so each id is a hash of
// the event (plus the occurrence's date for a repeating one), and the bridge keeps a
// table from id back to the event in event-ids.json.

import CryptoKit
import EventKit
import Foundation

// MARK: - Event ids

struct EventRef: Codable {
    let id: String          // EKEvent.eventIdentifier
    let occurrence: Date    // the occurrence's original date (repeating events)
    var start: Date         // where it was last seen
    var seen: Date
}

let refsURL = supportDir.appendingPathComponent("event-ids.json")
var eventRefs: [String: EventRef] = {
    guard let data = try? Data(contentsOf: refsURL),
          let refs = try? JSONDecoder().decode([String: EventRef].self, from: data) else { return [:] }
    return refs
}()
var refsChanged = false

func saveRefs() {
    guard refsChanged else { return }
    refsChanged = false
    if eventRefs.count > 20_000 {  // forget the ones not seen for longest
        for (key, _) in eventRefs.sorted(by: { $0.value.seen < $1.value.seen }).prefix(eventRefs.count - 15_000) {
            eventRefs.removeValue(forKey: key)
        }
    }
    try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(eventRefs) { try? data.write(to: refsURL, options: .atomic) }
}

func isRepeating(_ e: EKEvent) -> Bool { e.hasRecurrenceRules || e.isDetached }

func hashID(_ e: EKEvent) -> String {
    let id = e.eventIdentifier ?? e.calendarItemIdentifier
    let key = isRepeating(e) ? "\(id)|\(Int((e.occurrenceDate ?? e.startDate).timeIntervalSince1970))" : id
    return Insecure.SHA1.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
}

/// The event's short id, remembered so findEvent can get back to it.
func shortID(_ e: EKEvent) -> String {
    let short = hashID(e)
    let now = Date()
    if var ref = eventRefs[short] {
        if ref.start != e.startDate || now.timeIntervalSince(ref.seen) > 3600 {
            ref.start = e.startDate
            ref.seen = now
            eventRefs[short] = ref
            refsChanged = true
        }
    } else if let id = e.eventIdentifier {
        eventRefs[short] = EventRef(id: id, occurrence: e.occurrenceDate ?? e.startDate, start: e.startDate, seen: now)
        refsChanged = true
    }
    return short
}

func findEvent(_ raw: String) throws -> EKEvent {
    let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard key.count >= 4 else { throw ToolError(message: "Event ids are 8 characters") }
    let hits = eventRefs.filter { $0.key.hasPrefix(key) }
    guard let (short, ref) = hits.first else {
        throw ToolError(message: "No event \(key); list or search events to get current ids")
    }
    if hits.count > 1 { throw ToolError(message: "\(key) is ambiguous; use all 8 characters") }
    if let e = store.event(withIdentifier: ref.id), !isRepeating(e) { return e }
    let day: TimeInterval = 86_400
    for center in [ref.start, ref.occurrence] {
        let predicate = store.predicateForEvents(withStart: center - 2 * day, end: center + 2 * day, calendars: nil)
        if let e = store.events(matching: predicate).first(where: { $0.eventIdentifier == ref.id && hashID($0) == short }) {
            return e
        }
    }
    throw ToolError(message: "Event \(key) is gone (deleted, or its series moved); list events again")
}

// MARK: - Calendars

func eventCalendars() -> [EKCalendar] { store.calendars(for: .event) }

func accountName(_ c: EKCalendar) -> String { c.source?.title ?? "" }

/// A calendar by id, exact name, then a unique name prefix or substring.
func findCalendar(_ name: String) throws -> EKCalendar {
    let cals = eventCalendars()
    let needle = name.trimmingCharacters(in: .whitespaces).lowercased()
    let tests: [(EKCalendar) -> Bool] = [
        { $0.calendarIdentifier == name },
        { $0.title.lowercased() == needle },
        { $0.title.lowercased().hasPrefix(needle) },
        { $0.title.lowercased().contains(needle) },
    ]
    for test in tests {
        let hits = cals.filter(test)
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            throw ToolError(message: "\"\(name)\" matches several calendars; use an id: "
                            + hits.map { "\($0.title) (\(accountName($0)), \($0.calendarIdentifier))" }.joined(separator: ", "))
        }
    }
    throw ToolError(message: "No calendar matches \"\(name)\"; calendars: "
                    + cals.map { $0.title }.sorted().joined(separator: ", "))
}

/// PB_DEFAULT_CALENDAR (name or id) if set, else Calendar.app's default calendar.
func defaultEventCalendar() throws -> EKCalendar {
    if let name = environment["PB_DEFAULT_CALENDAR"], !name.isEmpty { return try findCalendar(name) }
    if let c = store.defaultCalendarForNewEvents { return c }
    throw ToolError(message: "No default calendar; pass calendar")
}

func requireWritableCalendar(_ c: EKCalendar) throws {
    if !c.allowsContentModifications { throw ToolError(message: "The calendar \"\(c.title)\" is read-only") }
}

// MARK: - Formatting

func clock(_ d: Date) -> String { formatter("h:mma").string(from: d).lowercased() }

func dayLabel(_ d: Date) -> String {
    let sameYear = Calendar.current.component(.year, from: d) == Calendar.current.component(.year, from: Date())
    return formatter(sameYear ? "EEE MMM d" : "EEE MMM d yyyy").string(from: d)
}

/// The last day an all-day event covers. EventKit reports the end either as the
/// last day at 23:59:59 or as the next midnight, depending on the account.
func lastDay(_ e: EKEvent) -> Date {
    let cal = Calendar.current
    let start = cal.startOfDay(for: e.startDate)
    var end = e.endDate ?? e.startDate!
    if end > e.startDate, end == cal.startOfDay(for: end) { end = end - 1 }
    return max(start, cal.startOfDay(for: end))
}

func span(_ e: EKEvent) -> String {
    if e.isAllDay {
        let last = lastDay(e)
        return Calendar.current.isDate(last, inSameDayAs: e.startDate) ? "all day" : "all day → \(dayLabel(last))"
    }
    if Calendar.current.isDate(e.startDate, inSameDayAs: e.endDate) { return "\(clock(e.startDate))–\(clock(e.endDate))" }
    return "\(clock(e.startDate)) → \(formatter("EEE").string(from: e.endDate)) \(clock(e.endDate))"
}

func statusWord(_ e: EKEvent) -> String? {
    switch e.status {
    case .canceled: return "cancelled"
    case .tentative: return "tentative"
    default: return nil
    }
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func eventLine(_ e: EKEvent) -> String {
    var line = "\(shortID(e))  \(pad(span(e), 17))  \(e.title ?? "(No title)") · \(e.calendar?.title ?? "")"
    if let place = e.location, !place.isEmpty { line += " @ " + place.replacingOccurrences(of: "\n", with: ", ") }
    if isRepeating(e) { line += " ↻" }
    if let status = statusWord(e) { line += " " + status }
    return line
}

/// Events grouped under day headings; each is listed on its first day in the range.
func agendaText(_ events: [EKEvent], from start: Date, empty: String = "nothing scheduled") -> String {
    if events.isEmpty { return empty }
    let cal = Calendar.current
    var days: [Date: [EKEvent]] = [:]
    for e in events { days[cal.startOfDay(for: max(e.startDate, start)), default: []].append(e) }
    return days.keys.sorted().map { day in
        ([dayLabel(day)] + days[day]!.map { "  " + eventLine($0) }).joined(separator: "\n")
    }.joined(separator: "\n\n")
}

let meetingPattern = try! NSRegularExpression(pattern:
    #"https?://[^\s<>"]*(zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com|gotomeeting\.com|facetime\.apple\.com)[^\s<>"]*"#,
    options: [.caseInsensitive])

func meetingURL(_ e: EKEvent) -> String? {
    for text in [e.url?.absoluteString, e.location, e.notes].compactMap({ $0 }) {
        if let m = meetingPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
            return (text as NSString).substring(with: m.range)
        }
    }
    return nil
}

/// Google stores notes as HTML.
func plainText(_ text: String) -> String {
    guard text.contains("<") else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var t = text.replacingOccurrences(of: #"(?i)<br\s*/?>|</p>|</div>|</li>"#, with: "\n", options: .regularExpression)
    t = t.replacingOccurrences(of: #"(?i)<a\s[^>]*href="([^"]*)"[^>]*>(.*?)</a>"#, with: "$2 ($1)", options: .regularExpression)
    t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
        t = t.replacingOccurrences(of: entity, with: char)
    }
    return t.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func repeatSummary(_ e: EKEvent) -> String? {
    guard let rule = e.recurrenceRules?.first else { return isRepeating(e) ? "repeats" : nil }
    let spec = describeRule(rule)
    var text = "repeats " + (spec["frequency"] as? String ?? "")
    if let n = spec["interval"] as? Int, n > 1 { text += ", every \(n)" }
    if let days = spec["days_of_week"] as? [String] { text += " on " + days.joined(separator: ", ") }
    if let days = spec["days_of_month"] as? [Int] { text += " on day " + days.map(String.init).joined(separator: ", ") }
    if let until = spec["until"] as? String { text += " until \(until)" }
    if let count = spec["count"] as? Int { text += ", \(count) times" }
    return text
}

func participantStatus(_ p: EKParticipant) -> String {
    switch p.participantStatus {
    case .accepted: return "accepted"
    case .declined: return "declined"
    case .tentative: return "maybe"
    case .pending: return "no reply"
    case .delegated: return "delegated"
    default: return ""
    }
}

func participantName(_ p: EKParticipant) -> String {
    if let name = p.name, !name.isEmpty { return name }
    return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
}

func showText(_ e: EKEvent) -> String {
    let when: String
    if e.isAllDay {
        let last = lastDay(e)
        when = dayLabel(e.startDate) + (Calendar.current.isDate(last, inSameDayAs: e.startDate) ? "" : " → \(dayLabel(last))") + ", all day"
    } else {
        when = "\(dayLabel(e.startDate)), \(span(e))"
    }
    var lines = [e.title ?? "(No title)", "  when       \(when)"]
    if let rule = repeatSummary(e) { lines.append("  repeat     \(rule)") }
    lines.append("  calendar   \(e.calendar?.title ?? "") (\(e.calendar.map(accountName) ?? ""))")
    if let place = e.location, !place.isEmpty { lines.append("  where      \(place)") }
    let meeting = meetingURL(e)
    if let meeting = meeting, !(e.location ?? "").contains(meeting) { lines.append("  meeting    \(meeting)") }
    if let url = e.url?.absoluteString, url != meeting { lines.append("  link       \(url)") }
    if let status = statusWord(e) { lines.append("  status     \(status)") }
    if let organizer = e.organizer { lines.append("  organizer  \(participantName(organizer))") }
    let attendees = (e.attendees ?? []).filter { !$0.isCurrentUser || e.organizer?.isCurrentUser == false }
    if !attendees.isEmpty {
        lines.append("  attendees  " + attendees.map { p -> String in
            let status = participantStatus(p)
            return participantName(p) + (p.isCurrentUser ? " (you)" : "") + (status.isEmpty ? "" : " – \(status)")
        }.joined(separator: "\n             "))
    }
    lines.append("  id         \(shortID(e))")
    if let notes = e.notes, !plainText(notes).isEmpty { lines += ["", plainText(notes)] }
    return lines.joined(separator: "\n")
}

// MARK: - Reading

/// Events overlapping [start, end), all-day first within a day, then by time.
/// EventKit refuses spans over four years, so long ranges go in yearly slices.
func events(from start: Date, to end: Date, calendars: [EKCalendar]?, words: [String] = []) -> [EKEvent] {
    var found: [EKEvent] = []
    var seen = Set<String>()
    var sliceStart = start
    while sliceStart < end {
        let sliceEnd = min(end, sliceStart + 365 * 86_400)
        for e in store.events(matching: store.predicateForEvents(withStart: sliceStart, end: sliceEnd, calendars: calendars)) {
            let key = "\(e.eventIdentifier ?? "")|\(e.startDate.timeIntervalSince1970)"
            if seen.insert(key).inserted { found.append(e) }
        }
        sliceStart = sliceEnd
    }
    if !words.isEmpty {
        found = found.filter { e in
            let hay = ([e.title, e.location, e.notes].compactMap { $0 }
                       + (e.attendees ?? []).map(participantName)).joined(separator: " ").lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
    }
    let cal = Calendar.current
    return found.sorted {
        let (a, b) = (cal.startOfDay(for: $0.startDate), cal.startOfDay(for: $1.startDate))
        if a != b { return a < b }
        if $0.isAllDay != $1.isAllDay { return $0.isAllDay }
        if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
        return ($0.title ?? "") < ($1.title ?? "")
    }
}

/// An end bound: a bare date means through the end of that day.
func endBound(_ text: String) throws -> Date {
    let when = try parseWhen(text)
    return when.hasTime ? when.date : Calendar.current.date(byAdding: .day, value: 1, to: when.date)!
}

func calendarFilter(_ args: [String: Any]) throws -> [EKCalendar]? {
    try (args["calendar"] as? String).flatMap { $0.isEmpty ? nil : [try findCalendar($0)] }
}

func listCalendars(_ args: [String: Any]) throws -> Any {
    let defaultID = (try? defaultEventCalendar())?.calendarIdentifier
    let cals = eventCalendars().sorted {
        ($0.allowsContentModifications ? 0 : 1, accountName($0).lowercased(), $0.title.lowercased())
            < ($1.allowsContentModifications ? 0 : 1, accountName($1).lowercased(), $1.title.lowercased())
    }
    if cals.isEmpty { return "No calendars. Add accounts in System Settings → Internet Accounts." }
    let width = cals.map { $0.title.count }.max() ?? 0
    let accountWidth = cals.map { accountName($0).count }.max() ?? 0
    return cals.map { c in
        var flags: [String] = []
        if !c.allowsContentModifications { flags.append("read-only") }
        if c.calendarIdentifier == defaultID { flags.append("default") }
        return "\(pad(c.title, width))  \(pad(accountName(c), accountWidth))  \(pad(flags.joined(separator: ", "), 18))  \(c.calendarIdentifier)"
    }.joined(separator: "\n")
}

func listEvents(_ args: [String: Any]) throws -> Any {
    let cal = Calendar.current
    let begin = try (args["start"] as? String).map { try parseWhen($0).date } ?? cal.startOfDay(for: Date())
    let end: Date
    if let text = args["end"] as? String {
        end = try endBound(text)
    } else {
        end = cal.date(byAdding: .day, value: max(1, args["days"] as? Int ?? 7), to: cal.startOfDay(for: begin))!
    }
    guard end > begin else { throw ToolError(message: "The end is before the start") }
    return agendaText(events(from: begin, to: end, calendars: try calendarFilter(args)), from: begin)
}

func searchEvents(_ args: [String: Any]) throws -> Any {
    guard let query = args["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ToolError(message: "query is required")
    }
    let today = Calendar.current.startOfDay(for: Date())
    let until = try (args["until"] as? String).map(endBound)
    var since = try (args["since"] as? String).map { try parseWhen($0).date } ?? today
    if args["since"] == nil, let until = until, until <= since { since = until - 366 * 86_400 }
    let end = until ?? since + 366 * 86_400
    let found = events(from: since, to: end, calendars: try calendarFilter(args),
                       words: query.lowercased().split(separator: " ").map(String.init))
    let limit = max(1, args["limit"] as? Int ?? 25)
    var text = agendaText(Array(found.prefix(limit)), from: since, empty: "no events match \"\(query)\" between \(dayLabel(since)) and \(dayLabel(end - 1))")
    if found.count > limit { text += "\n… and \(found.count - limit) more (raise the limit or narrow the dates)" }
    return text
}

func getEvent(_ args: [String: Any]) throws -> Any {
    showText(try findEvent(args["event_id"] as? String ?? ""))
}

// MARK: - Writing

/// "daily", "weekdays", "weekly", "monthly", "yearly", an RRULE like
/// "FREQ=WEEKLY;BYDAY=TU,TH", or the reminders tools' repeat object.
func parseRepeat(_ value: Any?) throws -> EKRecurrenceRule? {
    if let spec = value as? [String: Any] { return try parseRule(spec) }
    guard let raw = (value as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
    switch raw.lowercased() {
    case "daily", "weekly", "monthly", "yearly": return try parseRule(["frequency": raw.lowercased()])
    case "weekdays": return try parseRule(["frequency": "weekly", "days_of_week": ["mon", "tue", "wed", "thu", "fri"]])
    default: break
    }
    var spec: [String: Any] = [:]
    let body = raw.uppercased().hasPrefix("RRULE:") ? String(raw.dropFirst(6)) : raw
    let days = ["MO": "mon", "TU": "tue", "WE": "wed", "TH": "thu", "FR": "fri", "SA": "sat", "SU": "sun"]
    func ints(_ v: String) throws -> [Int] {
        try v.split(separator: ",").map { guard let n = Int($0) else { throw ToolError(message: "Bad number \($0) in \(raw)") }; return n }
    }
    for part in body.split(separator: ";") {
        let kv = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
        guard kv.count == 2 else { throw ToolError(message: "Can't read the repeat rule \"\(raw)\"") }
        let (key, v) = (kv[0].uppercased(), kv[1].uppercased())
        switch key {
        case "FREQ": spec["frequency"] = v.lowercased()
        case "INTERVAL": spec["interval"] = Int(v) ?? 0
        case "COUNT": spec["count"] = Int(v) ?? 0
        case "BYMONTHDAY": spec["days_of_month"] = try ints(v)
        case "BYMONTH": spec["months_of_year"] = try ints(v)
        case "BYSETPOS": spec["set_positions"] = try ints(v)
        case "BYDAY":
            spec["days_of_week"] = try v.split(separator: ",").map { entry -> String in
                let code = String(entry.suffix(2))
                guard let day = days[code] else { throw ToolError(message: "Bad day \(entry) in \(raw)") }
                return entry.dropLast(2) + day
            }
        case "UNTIL":
            guard let date = formatter("yyyyMMdd").date(from: String(v.prefix(8))) else {
                throw ToolError(message: "Bad UNTIL in \(raw)")
            }
            spec["until"] = formatter("yyyy-MM-dd").string(from: date)
        case "WKST": break
        default: throw ToolError(message: "The repeat rule part \(key) isn't supported")
        }
    }
    guard spec["frequency"] != nil else {
        throw ToolError(message: "Can't read the repeat rule \"\(raw)\"; use daily, weekdays, weekly, monthly, yearly or an RRULE")
    }
    return try parseRule(spec)
}


/// Sets an all-day span covering first...last (whole days).
func setAllDay(_ e: EKEvent, first: Date, last: Date) throws {
    guard last >= first else { throw ToolError(message: "The end is before the start") }
    e.isAllDay = true
    e.startDate = first
    e.endDate = last
}

func createEvent(_ args: [String: Any]) throws -> Any {
    guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ToolError(message: "title is required")
    }
    guard let startText = args["start"] as? String else { throw ToolError(message: "start is required") }
    if args["end"] != nil && args["duration"] != nil { throw ToolError(message: "Pass end or duration, not both") }
    let target = try (args["calendar"] as? String).map(findCalendar) ?? defaultEventCalendar()
    try requireWritableCalendar(target)
    let start = try parseWhen(startText)
    let length = try (args["duration"] as? String).map(parseDuration)
    let e = EKEvent(eventStore: store)
    e.calendar = target
    e.title = title
    e.timeZone = .current
    let cal = Calendar.current
    if args["all_day"] as? Bool ?? !start.hasTime {
        let first = cal.startOfDay(for: start.date)
        let last: Date
        if let end = args["end"] as? String {
            last = cal.startOfDay(for: try parseWhen(end).date)
        } else if let length = length {
            last = cal.date(byAdding: .day, value: max(1, Int((length / 86_400).rounded(.up))) - 1, to: first)!
        } else {
            last = first
        }
        try setAllDay(e, first: first, last: last)
    } else {
        e.startDate = start.date
        e.endDate = try (args["end"] as? String).map { try parseWhen($0).date } ?? start.date + (length ?? 3600)
        guard e.endDate > e.startDate else { throw ToolError(message: "The end is before the start") }
    }
    var location = args["location"] as? String ?? ""
    if let link = args["meeting_link"] as? String, !link.isEmpty {
        guard let url = URL(string: link), url.scheme != nil else { throw ToolError(message: "Bad meeting_link \(link)") }
        e.url = url
        if !location.contains(link) { location = location.isEmpty ? link : "\(location) · \(link)" }
    }
    if !location.isEmpty { e.location = location }
    if let notes = args["notes"] as? String, !notes.isEmpty { e.notes = notes }
    if let rule = try parseRepeat(args["repeat"]) { e.addRecurrenceRule(rule) }
    try store.save(e, span: .thisEvent, commit: true)
    return "added:\n" + showText(e)
}

/// Applies start/end/duration/all_day to one event (or one occurrence).
func applyTimes(_ e: EKEvent, _ args: [String: Any]) throws {
    let cal = Calendar.current
    let start = try (args["start"] as? String).map(parseWhen)
    let end = try (args["end"] as? String).map(parseWhen)
    let length = try (args["duration"] as? String).map(parseDuration)
    let wasAllDay = e.isAllDay
    let oldStart: Date = e.startDate, oldEnd: Date = e.endDate
    if args["all_day"] as? Bool ?? wasAllDay {
        let first = cal.startOfDay(for: start?.date ?? oldStart)
        let last: Date
        if let end = end {
            last = cal.startOfDay(for: end.date)
        } else if let length = length {
            last = cal.date(byAdding: .day, value: max(1, Int((length / 86_400).rounded(.up))) - 1, to: first)!
        } else if wasAllDay {
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: oldStart), to: lastDay(e)).day ?? 0
            last = cal.date(byAdding: .day, value: days, to: first)!
        } else {
            last = first
        }
        try setAllDay(e, first: first, last: last)
    } else {
        if wasAllDay && start == nil { throw ToolError(message: "Give start to turn an all-day event into a timed one") }
        let begin = start?.date ?? oldStart
        let finish: Date
        if let end = end { finish = end.date }
        else if let length = length { finish = begin + length }
        else if wasAllDay { finish = begin + 3600 }
        else { finish = begin + oldEnd.timeIntervalSince(oldStart) }
        guard finish > begin else { throw ToolError(message: "The end is before the start") }
        e.isAllDay = false
        e.startDate = begin
        e.endDate = finish
    }
}

func withClock(_ day: Date, _ clock: Date) -> Date {
    let c = Calendar.current.dateComponents([.hour, .minute], from: clock)
    return Calendar.current.date(bySettingHour: c.hour!, minute: c.minute!, second: 0, of: day)!
}

func applyText(_ e: EKEvent, _ args: [String: Any]) {
    if let title = args["title"] as? String, !title.isEmpty { e.title = title }
    if let location = args["location"] as? String { e.location = location.isEmpty ? nil : location }
    if let notes = args["notes"] as? String { e.notes = notes.isEmpty ? nil : notes }
}

func updateEvent(_ args: [String: Any]) throws -> Any {
    let e = try findEvent(args["event_id"] as? String ?? "")
    try requireWritableCalendar(e.calendar)
    if args["end"] != nil && args["duration"] != nil { throw ToolError(message: "Pass end or duration, not both") }
    let repeating = isRepeating(e)
    let series = repeating && (args["series"] as? Bool ?? false)
    let movesTime = ["start", "end", "duration", "all_day"].contains { args[$0] != nil }

    if let name = args["calendar"] as? String, !name.isEmpty {
        let target = try findCalendar(name)
        if target.calendarIdentifier != e.calendar.calendarIdentifier {
            if repeating { throw ToolError(message: "Can't move a repeating event to another calendar; recreate it there") }
            try requireWritableCalendar(target)
            e.calendar = target
        }
    }

    if series {
        guard let id = e.eventIdentifier, let first = store.event(withIdentifier: id) else {
            throw ToolError(message: "Can't find the first occurrence of this series")
        }
        if movesTime {
            if args["all_day"] != nil && args["all_day"] as? Bool != first.isAllDay {
                throw ToolError(message: "Can't switch a whole series between all-day and timed; do it per occurrence")
            }
            if first.isAllDay { throw ToolError(message: "A series edit can't move all-day events to other days") }
            // Every occurrence keeps its date; only the time of day changes.
            let begin = try (args["start"] as? String).map { withClock(first.startDate, try parseWhen($0).date) } ?? first.startDate!
            let finish: Date
            if let end = args["end"] as? String { finish = withClock(begin, try parseWhen(end).date) }
            else if let length = try (args["duration"] as? String).map(parseDuration) { finish = begin + length }
            else { finish = begin + first.endDate.timeIntervalSince(first.startDate) }
            guard finish > begin else { throw ToolError(message: "The end is before the start") }
            first.startDate = begin
            first.endDate = finish
        }
        applyText(first, args)
        try store.save(first, span: .futureEvents, commit: true)
        let refreshed = store.event(withIdentifier: id) ?? first
        return "updated (every occurrence):\n" + showText(refreshed)
    }

    if movesTime { try applyTimes(e, args) }
    applyText(e, args)
    try store.save(e, span: .thisEvent, commit: true)
    return "updated:\n" + showText(e)
}

func deleteEvent(_ args: [String: Any]) throws -> Any {
    let e = try findEvent(args["event_id"] as? String ?? "")
    try requireWritableCalendar(e.calendar)
    let summary = "\(e.title ?? "(No title)") (\(dayLabel(e.startDate)), \(e.calendar?.title ?? ""))"
    if isRepeating(e) && args["series"] as? Bool == true {
        guard let id = e.eventIdentifier, let first = store.event(withIdentifier: id) else {
            throw ToolError(message: "Can't find the first occurrence of this series")
        }
        try store.remove(first, span: .futureEvents, commit: true)
        return "deleted the whole series: \(summary)"
    }
    try store.remove(e, span: .thisEvent, commit: true)
    return "deleted \(isRepeating(e) ? "that occurrence" : "it"): \(summary)"
}

func syncCalendars(_ args: [String: Any]) throws -> Any {
    store.refreshSourcesIfNecessary()
    return "Asked every account to check for changes. The Mac also syncs on its own (iCloud by push, "
        + "Google every few minutes), so results can lag the web by a little."
}

// MARK: - Tools

let whenProperty: [String: Any] = ["type": "string", "description":
    "ISO 8601 (\"2026-10-01 14:00\", \"2026-10-01\") or plain English (\"tomorrow 3pm\", \"next fri\"), local time"]
let durationProperty: [String: Any] = ["type": "string", "description": "Length like 30m, 1h, 1h30m, 2d"]
let calendarProperty: [String: Any] = ["type": "string", "description": "Calendar name (or a unique part of it) or id"]
let eventProperty: [String: Any] = ["type": "string", "description": "8-character event id"]
let seriesProperty: [String: Any] = ["type": "boolean", "default": false,
                                     "description": "For a repeating event: apply to every occurrence, not just this one"]

/// Wraps a calendar tool so the id table is saved after it runs.
func savingRefs(_ run: @escaping ([String: Any]) throws -> Any) -> ([String: Any]) throws -> Any {
    { args in
        defer { saveRefs() }
        return try run(args)
    }
}

let calendarTools: [Tool] = [
    Tool(name: "list_calendars", description: "The calendars, with account, whether they're read-only, and which is the default.",
         schema: schema([:]), readOnly: true, destructive: false, run: savingRefs(listCalendars)),
    Tool(name: "list_events",
         description: "Events between two times, grouped by day, all-day events first. Defaults to today plus the next 6 days. "
             + "A bare date as end means through the end of that day.",
         schema: schema(["start": whenProperty, "end": whenProperty,
                         "days": ["type": "integer", "description": "Instead of end: this many days from start"],
                         "calendar": calendarProperty]),
         readOnly: true, destructive: false, run: savingRefs(listEvents)),
    Tool(name: "search_events",
         description: "Find events whose title, location, notes or attendees contain every word of the query. "
             + "Searches a year from today unless since/until are given.",
         schema: schema(["query": ["type": "string"], "since": whenProperty, "until": whenProperty,
                         "calendar": calendarProperty, "limit": ["type": "integer", "default": 25]], required: ["query"]),
         readOnly: true, destructive: false, run: savingRefs(searchEvents)),
    Tool(name: "get_event", description: "One event in full: notes, meeting link, organizer and attendees.",
         schema: schema(["event_id": eventProperty], required: ["event_id"]),
         readOnly: true, destructive: false, run: savingRefs(getEvent)),
    Tool(name: "create_event",
         description: "Create an event. Timed events last 1 hour unless end or duration is given. A start with no time "
             + "of day makes an all-day event (one day unless end or duration says more). Without calendar it uses the default calendar.",
         schema: schema(["title": ["type": "string"], "start": whenProperty, "end": whenProperty, "duration": durationProperty,
                         "all_day": ["type": "boolean"], "calendar": calendarProperty,
                         "location": ["type": "string"], "notes": ["type": "string"],
                         "repeat": ["type": "string", "description": "daily, weekdays, weekly, monthly, yearly, or an RRULE like FREQ=WEEKLY;BYDAY=TU,TH"],
                         "meeting_link": ["type": "string", "description": "Zoom/Meet/Teams URL"]],
                        required: ["title", "start"]),
         readOnly: false, destructive: false, run: savingRefs(createEvent)),
    Tool(name: "update_event",
         description: "Change an event: only the fields given change, and the length is kept when only start moves. "
             + "calendar moves a one-off event to another calendar. On a repeating event it changes just that occurrence "
             + "unless series=true; with series=true every occurrence keeps its date and start/end set only the time of day.",
         schema: schema(["event_id": eventProperty, "title": ["type": "string"], "start": whenProperty, "end": whenProperty,
                         "duration": durationProperty, "location": ["type": "string", "description": "\"\" clears it"],
                         "notes": ["type": "string", "description": "Replaces the notes; \"\" clears them"],
                         "calendar": calendarProperty, "all_day": ["type": "boolean"], "series": seriesProperty],
                        required: ["event_id"]),
         readOnly: false, destructive: false, run: savingRefs(updateEvent)),
    Tool(name: "delete_event", description: "Delete an event, or one occurrence of a repeating event (series=true deletes them all).",
         schema: schema(["event_id": eventProperty, "series": seriesProperty], required: ["event_id"]),
         readOnly: false, destructive: true, run: savingRefs(deleteEvent)),
    Tool(name: "sync_calendars", description: "Ask every calendar account to check its server for changes now.",
         schema: schema([:]), readOnly: false, destructive: false, run: syncCalendars),
]

let calendarInstructions = """
Ian's calendars, read on his Mac through EventKit: every account in System Settings → Internet \
Accounts (iCloud calendars, some shared with family, plus any Google or work accounts added there). \
Times are local (\(TimeZone.current.identifier)). Event ids are the 8-character ids printed next to \
each event. Creating, changing or deleting events changes Ian's real calendars, which family and \
coworkers may share: only do it when Ian asked for that specific change, and say what you did \
afterwards. These tools can't invite anyone, but changing an event that already has attendees \
may notify them through the calendar's server.
"""

let calendarServer = Server(
    name: "calendar", instructions: calendarInstructions, tools: calendarTools,
    accessProblem: {
        accessStatus(.event) == "fullAccess" ? nil : "Calendar access is \(accessStatus(.event)) on the Mac. Allow PIM Bridge in "
            + "System Settings → Privacy & Security → Calendars."
    },
    prepare: { store.reset() })

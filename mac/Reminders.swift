// Apple Reminders through EventKit, plus ReminderKit for the URL field.
// Moved from github.com/ianneub/reminders-bridge, where it served the Omarchy desktop.

import EventKit
import Foundation

let store = EKEventStore()

func accessStatus(_ type: EKEntityType = .reminder) -> String {
    switch EKEventStore.authorizationStatus(for: type) {
    case .fullAccess: return "fullAccess"
    case .writeOnly: return "writeOnly"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func fetch(_ predicate: NSPredicate) -> [EKReminder] {
    let done = DispatchSemaphore(value: 0)
    var result: [EKReminder] = []
    store.fetchReminders(matching: predicate) { reminders in
        result = reminders ?? []
        done.signal()
    }
    done.wait()
    return result
}

func reminderLists() -> [EKCalendar] { store.calendars(for: .reminder) }

func resolveList(_ ref: String) throws -> EKCalendar {
    let lists = reminderLists()
    if let exact = lists.first(where: { $0.calendarIdentifier == ref }) { return exact }
    let named = lists.filter { $0.title.caseInsensitiveCompare(ref) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.isEmpty {
        throw ToolError(message: "No reminder list named \"\(ref)\". Lists: "
                        + lists.map { $0.title }.sorted().joined(separator: ", "))
    }
    throw ToolError(message: "Several lists are named \"\(ref)\"; pass the list id instead: "
                    + named.map { "\($0.calendarIdentifier) (\($0.source.title))" }.joined(separator: ", "))
}

func resolveReminder(_ args: [String: Any]) throws -> EKReminder {
    guard let id = args["id"] as? String, !id.isEmpty else { throw ToolError(message: "id is required") }
    guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
        throw ToolError(message: "No reminder with id \(id)")
    }
    return reminder
}

/// A due date: anything parseWhen reads. With a time of day it keeps the hour and
/// minute; a bare date stays date-only.
func parseDue(_ raw: String) throws -> DateComponents {
    let when = try parseWhen(raw)
    return Calendar.current.dateComponents(when.hasTime ? [.year, .month, .day, .hour, .minute]
                                                        : [.year, .month, .day], from: when.date)
}

/// The moment a due date refers to, in local time. Date-only reminders count as
/// due at the start of that day.
func dueDate(_ components: DateComponents?) -> Date? {
    guard var c = components, c.year != nil, c.month != nil, c.day != nil else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = (c.hour != nil ? c.timeZone : nil) ?? .current
    c.calendar = nil
    c.timeZone = nil
    return calendar.date(from: c)
}

func formatDue(_ components: DateComponents?) -> String? {
    guard let c = components, let date = dueDate(c) else { return nil }
    return formatter(c.hour != nil ? "yyyy-MM-dd'T'HH:mm" : "yyyy-MM-dd").string(from: date)
}

/// Sets or clears the due date. A due date with a time also gets an alert at that
/// time, the way Reminders.app does it -- without one nothing ever notifies.
func applyDue(_ reminder: EKReminder, _ value: Any?) throws {
    for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil {
        reminder.removeAlarm(alarm)
    }
    guard let text = value as? String, !text.isEmpty else {
        reminder.dueDateComponents = nil
        return
    }
    let components = try parseDue(text)
    reminder.dueDateComponents = components
    if components.hour != nil, let date = dueDate(components) {
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }
}

func priorityName(_ value: Int) -> String {
    switch value {
    case 0: return "none"
    case 1...4: return "high"
    case 5: return "medium"
    default: return "low"
    }
}

func priorityValue(_ name: String) throws -> Int {
    switch name.lowercased() {
    case "none": return 0
    case "high": return 1
    case "medium": return 5
    case "low": return 9
    default: throw ToolError(message: "priority must be none, low, medium or high")
    }
}

// MARK: - Repeat rules

// A reminder's repeat rule as JSON, in the shape the tools take and return:
//   {"frequency": "weekly", "interval": 2, "days_of_week": ["mon", "wed"],
//    "days_of_month": [1, -1], "months_of_year": [11], "set_positions": [1],
//    "until": "2026-12-31" | "count": 10}
// A days_of_week entry may carry a week number for monthly and yearly rules:
// "1mon" is the first Monday, "-1fri" the last Friday. Reminders.app makes one
// rule per reminder, so only the first is read.

let weekdayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]  // EKWeekday raw value - 1
let frequencies: [(String, EKRecurrenceFrequency)] = [("daily", .daily), ("weekly", .weekly),
                                                      ("monthly", .monthly), ("yearly", .yearly)]

func describeRule(_ rule: EKRecurrenceRule) -> [String: Any] {
    var out: [String: Any] = [
        "frequency": frequencies.first { $0.1 == rule.frequency }?.0 ?? "unknown",
        "interval": rule.interval,
    ]
    if let days = rule.daysOfTheWeek, !days.isEmpty {
        out["days_of_week"] = days.map {
            ($0.weekNumber != 0 ? String($0.weekNumber) : "") + weekdayNames[$0.dayOfTheWeek.rawValue - 1]
        }
    }
    if let days = rule.daysOfTheMonth, !days.isEmpty { out["days_of_month"] = days.map { $0.intValue } }
    if let months = rule.monthsOfTheYear, !months.isEmpty { out["months_of_year"] = months.map { $0.intValue } }
    if let positions = rule.setPositions, !positions.isEmpty { out["set_positions"] = positions.map { $0.intValue } }
    // Parts Reminders.app never sets; flagged so a client doesn't claim to show the whole rule.
    if rule.weeksOfTheYear?.isEmpty == false || rule.daysOfTheYear?.isEmpty == false { out["custom"] = true }
    if let end = rule.recurrenceEnd {
        if let date = end.endDate {
            out["until"] = formatter("yyyy-MM-dd").string(from: date)
        } else if end.occurrenceCount > 0 {
            out["count"] = end.occurrenceCount
        }
    }
    return out
}

/// The "repeat" argument as a rule; nil for "" or null, which stop the repeat.
func parseRule(_ value: Any?) throws -> EKRecurrenceRule? {
    if value == nil || value is NSNull { return nil }
    if let text = value as? String, text.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
    guard let spec = value as? [String: Any] else {
        throw ToolError(message: "repeat must be an object like {\"frequency\": \"weekly\"}, or \"\" to stop repeating")
    }
    let known: Set = ["frequency", "interval", "days_of_week", "days_of_month", "months_of_year",
                      "set_positions", "until", "count"]
    if let extra = spec.keys.first(where: { !known.contains($0) }) {
        throw ToolError(message: "repeat has no field \"\(extra)\"")
    }
    let name = (spec["frequency"] as? String ?? "").lowercased()
    guard let frequency = frequencies.first(where: { $0.0 == name })?.1 else {
        throw ToolError(message: "repeat.frequency must be daily, weekly, monthly or yearly")
    }
    let interval = spec["interval"] == nil ? 1 : (spec["interval"] as? Int ?? 0)
    guard interval >= 1 else { throw ToolError(message: "repeat.interval must be a whole number, 1 or more") }

    func numbers(_ key: String, _ range: ClosedRange<Int>) throws -> [NSNumber]? {
        guard let raw = spec[key] else { return nil }
        guard let list = raw as? [Int], list.allSatisfy({ range.contains($0) && $0 != 0 }) else {
            throw ToolError(message: "repeat.\(key) must be a list of numbers from \(range.lowerBound) to \(range.upperBound), not 0")
        }
        return list.isEmpty ? nil : list.map { NSNumber(value: $0) }
    }
    let daysOfMonth = try numbers("days_of_month", -31...31)
    let months = try numbers("months_of_year", 1...12)
    let positions = try numbers("set_positions", -366...366)

    var days: [EKRecurrenceDayOfWeek]? = nil
    if let raw = spec["days_of_week"] {
        guard let list = raw as? [String] else {
            throw ToolError(message: "repeat.days_of_week must be a list like [\"mon\", \"wed\"] or [\"1mon\"]")
        }
        days = try list.map { entry in
            let text = entry.lowercased().trimmingCharacters(in: .whitespaces)
            let digits = text.prefix { "-+0123456789".contains($0) }
            let word = text.dropFirst(digits.count)
            guard word.count >= 3, let index = weekdayNames.firstIndex(of: String(word.prefix(3))),
                  let week = digits.isEmpty ? 0 : Int(digits), (-5...5).contains(week) else {
                throw ToolError(message: "Can't read the day \"\(entry)\"; use mon..sun, optionally with a week number like 1mon or -1fri")
            }
            if week != 0 && frequency != .monthly && frequency != .yearly {
                throw ToolError(message: "A week number like \"\(entry)\" only works with a monthly or yearly repeat")
            }
            return EKRecurrenceDayOfWeek(EKWeekday(rawValue: index + 1)!, weekNumber: week)
        }
        if days!.isEmpty { days = nil }
    }
    if days != nil && frequency == .daily {
        throw ToolError(message: "A daily repeat can't pick days of the week; use weekly")
    }
    if daysOfMonth != nil && frequency != .monthly {
        throw ToolError(message: "repeat.days_of_month only works with a monthly repeat")
    }
    if months != nil && frequency != .yearly {
        throw ToolError(message: "repeat.months_of_year only works with a yearly repeat")
    }
    if positions != nil && days == nil {
        throw ToolError(message: "repeat.set_positions needs days_of_week")
    }

    var end: EKRecurrenceEnd? = nil
    if let until = spec["until"] as? String, !until.isEmpty {
        guard let day = dueDate(try parseDue(until)) else { throw ToolError(message: "Bad repeat.until") }
        // The whole last day counts, whatever time the reminder is due.
        end = EKRecurrenceEnd(end: Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: day)!)
    }
    if let count = spec["count"] {
        guard end == nil else { throw ToolError(message: "Pass repeat.until or repeat.count, not both") }
        guard let n = count as? Int, n >= 1 else { throw ToolError(message: "repeat.count must be 1 or more") }
        end = EKRecurrenceEnd(occurrenceCount: n)
    }
    return EKRecurrenceRule(recurrenceWith: frequency, interval: interval, daysOfTheWeek: days,
                            daysOfTheMonth: daysOfMonth, monthsOfTheYear: months, weeksOfTheYear: nil,
                            daysOfTheYear: nil, setPositions: positions, end: end)
}

/// Applies "due" and "repeat" from args, checked before anything changes. Like
/// Reminders.app, a repeat needs a due date, and clearing the date stops the repeat.
func applySchedule(_ reminder: EKReminder, _ args: [String: Any]) throws {
    let changesRepeat = args.keys.contains("repeat")
    let rule = changesRepeat ? try parseRule(args["repeat"]) : nil
    let newDue = args["due"] as? String ?? ""
    let clearsDue = args.keys.contains("due") && newDue.isEmpty
    if !newDue.isEmpty { _ = try parseDue(newDue) }
    let willHaveDue = args.keys.contains("due") ? !clearsDue : reminder.dueDateComponents != nil
    if rule != nil && !willHaveDue {
        throw ToolError(message: "A repeating reminder needs a due date; pass due too")
    }
    if args.keys.contains("due") { try applyDue(reminder, args["due"]) }
    if changesRepeat || clearsDue {
        for old in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(old) }
        if let rule = rule { reminder.addRecurrenceRule(rule) }
    }
}

// MARK: - ReminderKit (the URL field)

// The URL field Reminders.app shows is a URL *attachment*, which EventKit never
// exposes. EKReminder.url is the old iCal URL property, which the app doesn't show.
// ReminderKit is the private framework EventKit itself sits on. remindd gives
// clients without Apple's entitlement the access their Reminders (TCC) grant
// allows, so it needs no extra permission. Selectors are checked before every call,
// so an OS update that renames one costs only the URL field, not the process.

@objc protocol RKStore {
    @objc(fetchRemindersWithDACalendarItemUniqueIdentifiers:inList:error:)
    func fetchReminders(_ ids: NSArray, inList list: AnyObject?) throws -> NSDictionary
}

@objc protocol RKSaveRequest {
    @objc(initWithStore:) init(store: AnyObject)
    @objc(updateReminder:) func update(_ reminder: AnyObject) -> AnyObject
    @objc(saveSynchronouslyWithError:) func saveSynchronously() throws
}

@objc protocol RKAttachmentChanges {
    @objc(setURLAttachmentWithURL:) func setURL(_ url: NSURL)
    @objc(removeURLAttachments) func removeURLs()
}

let rkStore: NSObject? = {
    guard dlopen("/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit", RTLD_NOW) != nil,
          let type = NSClassFromString("REMStore") as? NSObject.Type else {
        log("ReminderKit unavailable; the URL field falls back to EventKit's url")
        return nil
    }
    return type.init()
}()

func responds(_ object: AnyObject?, _ selectors: String...) -> Bool {
    guard let object = object else { return false }
    return selectors.allSatisfy { object.responds(to: NSSelectorFromString($0)) }
}

/// ReminderKit reminders by EventKit id (the same UUID in both).
func rkReminders(_ ids: [String]) throws -> [String: NSObject] {
    guard !ids.isEmpty else { return [:] }
    guard let store = rkStore, responds(store, "fetchRemindersWithDACalendarItemUniqueIdentifiers:inList:error:") else {
        throw ToolError(message: "ReminderKit can't fetch reminders on this macOS")
    }
    let found = try unsafeBitCast(store, to: RKStore.self).fetchReminders(ids as NSArray, inList: nil)
    var out: [String: NSObject] = [:]
    for (key, value) in found {
        guard let reminder = value as? NSObject else { continue }
        if let id = key as? String {
            out[id] = reminder
        } else if let uuid = (reminder.value(forKey: "remObjectID") as? NSObject)?.value(forKey: "uuid") as? UUID {
            out[uuid.uuidString] = reminder
        }
    }
    return out
}

/// The URL field of each reminder that has one, by EventKit id. Empty if
/// ReminderKit fails, so reads degrade to EventKit's url instead of failing.
func attachmentURLs(_ ids: [String]) -> [String: String] {
    do {
        var out: [String: String] = [:]
        for (id, reminder) in try rkReminders(ids) {
            guard responds(reminder, "attachmentContext"),
                  let context = reminder.value(forKey: "attachmentContext") as? NSObject,
                  responds(context, "urlAttachments"),
                  let first = (context.value(forKey: "urlAttachments") as? [NSObject])?.first,
                  responds(first, "url"), let url = first.value(forKey: "url") as? URL else { continue }
            out[id] = url.absoluteString
        }
        return out
    } catch {
        log("reading URL attachments failed: \(error)")
        return [:]
    }
}

/// Sets (or, with nil, removes) the URL field the way Reminders.app does.
func setAttachmentURL(_ id: String, _ url: URL?) throws {
    guard let store = rkStore, let reminder = try rkReminders([id])[id] else {
        throw ToolError(message: "ReminderKit can't find reminder \(id)")
    }
    guard let requestType = NSClassFromString("REMSaveRequest"),
          requestType.instancesRespond(to: NSSelectorFromString("initWithStore:")) else {
        throw ToolError(message: "ReminderKit has no save request on this macOS")
    }
    let request = unsafeBitCast(requestType, to: RKSaveRequest.Type.self).init(store: store)
    guard responds(request, "updateReminder:", "saveSynchronouslyWithError:") else {
        throw ToolError(message: "ReminderKit's save request changed on this macOS")
    }
    let change = request.update(reminder)
    guard responds(change, "attachmentContext"),
          let context = (change as? NSObject)?.value(forKey: "attachmentContext") as? NSObject,
          responds(context, "setURLAttachmentWithURL:", "removeURLAttachments") else {
        throw ToolError(message: "ReminderKit's attachment API changed on this macOS")
    }
    let attachments = unsafeBitCast(context, to: RKAttachmentChanges.self)
    if let url = url { attachments.setURL(url as NSURL) } else { attachments.removeURLs() }
    try request.saveSynchronously()
}

/// The "url" argument: an empty string clears it, anything else must parse.
func urlArgument(_ args: [String: Any]) throws -> URL? {
    guard let text = (args["url"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    guard let url = URL(string: text), url.scheme != nil else {
        throw ToolError(message: "Can't read the URL \"\(text)\"; include the scheme, like https://")
    }
    return url
}

/// Saves the URL field after EventKit has saved everything else, and drops
/// EventKit's iCal url so the reminder doesn't carry two different URLs.
func saveURL(_ reminder: EKReminder, _ url: URL?) throws {
    if reminder.url != nil {
        reminder.url = nil
        try store.save(reminder, commit: true)
    }
    do {
        try setAttachmentURL(reminder.calendarItemIdentifier, url)
    } catch {
        let reason = (error as? ToolError)?.message ?? "\(error)"
        throw ToolError(message: "Saved everything except the URL: \(reason)")
    }
}

/// `urls` is the URL field by id, from attachmentURLs; without it, this
/// reminder's is fetched on its own.
func describe(_ r: EKReminder, urls: [String: String]? = nil) -> [String: Any] {
    var out: [String: Any] = [
        "id": r.calendarItemIdentifier,
        "title": r.title ?? "",
        "list": r.calendar?.title ?? "",
        "list_id": r.calendar?.calendarIdentifier ?? "",
        "completed": r.isCompleted,
        "priority": priorityName(r.priority),
    ]
    if let due = formatDue(r.dueDateComponents) { out["due"] = due }
    if let notes = r.notes, !notes.isEmpty { out["notes"] = notes }
    // The app's URL field; EventKit's iCal url only when there's none.
    let id = r.calendarItemIdentifier
    if let url = (urls ?? attachmentURLs([id]))[id] ?? r.url?.absoluteString { out["url"] = url }
    if let rule = r.recurrenceRules?.first {
        out["recurring"] = true
        out["repeat"] = describeRule(rule)
    }
    if let date = r.completionDate { out["completed_at"] = timestamp(date) }
    if let date = r.creationDate { out["created_at"] = timestamp(date) }
    return out
}

func requireWritable(_ list: EKCalendar) throws {
    if !list.allowsContentModifications {
        throw ToolError(message: "The list \"\(list.title)\" is read-only")
    }
}

// MARK: - Tools

func listLists(_ args: [String: Any]) throws -> Any {
    let lists = reminderLists()
    var open: [String: Int] = [:]
    for r in fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)) {
        open[r.calendar.calendarIdentifier, default: 0] += 1
    }
    let defaultID = store.defaultCalendarForNewReminders()?.calendarIdentifier
    return lists.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }.map { c -> [String: Any] in
        [
            "id": c.calendarIdentifier,
            "name": c.title,
            "account": c.source?.title ?? "",
            "open": open[c.calendarIdentifier] ?? 0,
            "writable": c.allowsContentModifications,
            "default": c.calendarIdentifier == defaultID,
        ]
    }
}

func listReminders(_ args: [String: Any]) throws -> Any {
    let lists = try (args["list"] as? String).map { [try resolveList($0)] }
    let status = (args["status"] as? String ?? "incomplete").lowercased()
    let predicate: NSPredicate
    switch status {
    case "incomplete":
        predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
    case "completed":
        predicate = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: lists)
    case "all":
        predicate = store.predicateForReminders(in: lists)
    default:
        throw ToolError(message: "status must be incomplete, completed or all")
    }
    var items = fetch(predicate)

    if let raw = args["due_before"] as? String {
        let components = try parseDue(raw)
        guard var cutoff = dueDate(components) else { throw ToolError(message: "Bad due_before") }
        if components.hour == nil {  // a bare date means "by the end of that day"
            cutoff = Calendar.current.date(byAdding: .day, value: 1, to: cutoff)!
        }
        items = items.filter { dueDate($0.dueDateComponents).map { $0 < cutoff } ?? false }
    }
    if let query = args["search"] as? String, !query.isEmpty {
        items = items.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query)
                || ($0.notes ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    if status == "completed" {
        items.sort { ($0.completionDate ?? .distantPast) > ($1.completionDate ?? .distantPast) }
    } else {
        items.sort {
            let a = dueDate($0.dueDateComponents) ?? .distantFuture
            let b = dueDate($1.dueDateComponents) ?? .distantFuture
            return a != b ? a < b : ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
        }
    }

    let limit = max(1, (args["limit"] as? Int) ?? 100)
    let page = Array(items.prefix(limit))
    let urls = attachmentURLs(page.map { $0.calendarItemIdentifier })
    return [
        "total": items.count,
        "reminders": page.map { describe($0, urls: urls) },
    ] as [String: Any]
}

func createReminder(_ args: [String: Any]) throws -> Any {
    guard let title = args["title"] as? String, !title.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw ToolError(message: "title is required")
    }
    let reminder = EKReminder(eventStore: store)
    reminder.title = title
    if let list = args["list"] as? String {
        reminder.calendar = try resolveList(list)
    } else if let list = store.defaultCalendarForNewReminders() {
        reminder.calendar = list
    } else {
        throw ToolError(message: "No default reminder list; pass list")
    }
    try requireWritable(reminder.calendar)
    if let notes = args["notes"] as? String, !notes.isEmpty { reminder.notes = notes }
    try applySchedule(reminder, args)
    if let priority = args["priority"] as? String { reminder.priority = try priorityValue(priority) }
    let url = try urlArgument(args)
    try store.save(reminder, commit: true)
    if let url = url { try saveURL(reminder, url) }
    return describe(reminder)
}

func updateReminder(_ args: [String: Any]) throws -> Any {
    let reminder = try resolveReminder(args)
    try requireWritable(reminder.calendar)
    try applySchedule(reminder, args)  // first: it checks before it changes anything
    if let title = args["title"] as? String, !title.isEmpty { reminder.title = title }
    if args.keys.contains("notes") {
        reminder.notes = (args["notes"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
    if let priority = args["priority"] as? String { reminder.priority = try priorityValue(priority) }
    if let list = args["list"] as? String {
        let target = try resolveList(list)
        try requireWritable(target)
        reminder.calendar = target
    }
    if let completed = args["completed"] as? Bool { reminder.isCompleted = completed }
    let url = try urlArgument(args)
    try store.save(reminder, commit: true)
    if args.keys.contains("url") { try saveURL(reminder, url) }
    return describe(reminder)
}

func completeReminder(_ args: [String: Any]) throws -> Any {
    let reminder = try resolveReminder(args)
    try requireWritable(reminder.calendar)
    reminder.isCompleted = (args["completed"] as? Bool) ?? true
    try store.save(reminder, commit: true)
    return describe(reminder)
}

func deleteReminder(_ args: [String: Any]) throws -> Any {
    let reminder = try resolveReminder(args)
    try requireWritable(reminder.calendar)
    let gone = describe(reminder)
    try store.remove(reminder, commit: true)
    return ["deleted": gone]
}

let idProperty: [String: Any] = ["type": "string", "description": "Reminder id, from list_reminders"]
let dueProperty: [String: Any] = [
    "type": "string",
    "description": "YYYY-MM-DD for a date, or YYYY-MM-DDTHH:MM (local time) to also get an alert then; plain English like \"tomorrow 3pm\" works too. Empty string clears it.",
]
let priorityProperty: [String: Any] = ["type": "string", "enum": ["none", "low", "medium", "high"]]
let urlProperty: [String: Any] = ["type": "string", "description": "The URL field shown in Reminders.app, e.g. https://example.com"]
let repeatProperty: [String: Any] = [
    "description": "How it repeats, or \"\" to stop repeating. Needs a due date; clearing due also stops it. "
        + "The repeat counts from the due date.",
    "anyOf": [
        [
            "type": "object",
            "properties": [
                "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
                "interval": ["type": "integer", "minimum": 1, "default": 1, "description": "Every N days, weeks, months or years"],
                "days_of_week": ["type": "array", "items": ["type": "string"],
                                 "description": "mon..sun. For monthly/yearly, prefix a week number: 1mon = first Monday, -1fri = last Friday"],
                "days_of_month": ["type": "array", "items": ["type": "integer"], "description": "Monthly only: 1..31, -1 = last day"],
                "months_of_year": ["type": "array", "items": ["type": "integer", "minimum": 1, "maximum": 12], "description": "Yearly only"],
                "set_positions": ["type": "array", "items": ["type": "integer"],
                                  "description": "Which of the days_of_week matches count: [1] with mon..fri = the first weekday"],
                "until": ["type": "string", "description": "YYYY-MM-DD, the last day it can repeat"],
                "count": ["type": "integer", "minimum": 1, "description": "Stop after this many times"],
            ],
            "required": ["frequency"],
            "additionalProperties": false,
        ] as [String: Any],
        ["type": "string", "enum": [""]],
    ],
]
let listProperty: [String: Any] = ["type": "string", "description": "List name (case-insensitive) or list id"]

let reminderTools: [Tool] = [
    Tool(name: "list_lists",
         description: "List all reminder lists (including lists shared with family) with their open-item counts.",
         schema: schema([:]), readOnly: true, destructive: false, run: listLists),
    Tool(name: "list_reminders",
         description: "List reminders, soonest due first. Defaults to incomplete reminders across every list.",
         schema: schema([
             "list": listProperty,
             "status": ["type": "string", "enum": ["incomplete", "completed", "all"], "default": "incomplete"],
             "due_before": ["type": "string", "description": "Only reminders due before this: a bare date like YYYY-MM-DD or \"friday\" means by the end of that day"],
             "search": ["type": "string", "description": "Case-insensitive match on title or notes"],
             "limit": ["type": "integer", "default": 100, "minimum": 1],
         ]), readOnly: true, destructive: false, run: listReminders),
    Tool(name: "create_reminder",
         description: "Create a reminder. Without a list it goes to the default list.",
         schema: schema([
             "title": ["type": "string"],
             "list": listProperty,
             "notes": ["type": "string"],
             "due": dueProperty,
             "priority": priorityProperty,
             "url": urlProperty,
             "repeat": repeatProperty,
         ], required: ["title"]), readOnly: false, destructive: false, run: createReminder),
    Tool(name: "update_reminder",
         description: "Change a reminder. Only the fields you pass change; pass an empty string to clear notes, due, url or repeat. Passing list moves it.",
         schema: schema([
             "id": idProperty,
             "title": ["type": "string"],
             "list": listProperty,
             "notes": ["type": "string"],
             "due": dueProperty,
             "priority": priorityProperty,
             "completed": ["type": "boolean"],
             "url": urlProperty,
             "repeat": repeatProperty,
         ], required: ["id"]), readOnly: false, destructive: false, run: updateReminder),
    Tool(name: "complete_reminder",
         description: "Mark a reminder done (or not done, with completed: false).",
         schema: schema(["id": idProperty, "completed": ["type": "boolean", "default": true]], required: ["id"]),
         readOnly: false, destructive: false, run: completeReminder),
    Tool(name: "delete_reminder",
         description: "Permanently delete a reminder. Prefer complete_reminder unless deletion was asked for.",
         schema: schema(["id": idProperty], required: ["id"]), readOnly: false, destructive: true, run: deleteReminder),
]

let reminderInstructions = """
Apple Reminders from Ian's iCloud account, read on his Mac. Lists can be shared \
with family and are also used by HomePods, so changes show up for everyone on the list. \
Dates are in the Mac's local time zone (\(TimeZone.current.identifier)).
"""

let remindersServer = Server(
    name: "reminders", instructions: reminderInstructions, tools: reminderTools,
    accessProblem: {
        accessStatus() == "fullAccess" ? nil : "Reminders access is \(accessStatus()) on the Mac. Allow PIM Bridge in "
            + "System Settings → Privacy & Security → Reminders."
    },
    prepare: { store.reset() })  // drop cached objects so edits made on other devices show up

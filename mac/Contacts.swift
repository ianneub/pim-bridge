// Contacts through the Contacts framework: the Mac's address book, which is
// Ian's iCloud contacts. Results are text, laid out the way the Omarchy
// `contacts` CLI printed them, with an 8-character id per contact.

import AppKit
import Contacts
import CryptoKit
import Foundation

let contactStore = CNContactStore()

func contactsAccess() -> String {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: return "fullAccess"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    default: return "limited"
    }
}

let baseContactKeys: [CNKeyDescriptor] = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)] + ([
    CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
    CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey, CNContactTypeKey,
    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
    CNContactUrlAddressesKey, CNContactBirthdayKey, CNContactRelationsKey,
] as [CNKeyDescriptor])

let contactKeys = baseContactKeys

// MARK: - Contacts.app
//
// The Contacts framework hides notes from apps without an entitlement Apple grants
// only to approved apps: they read as empty, writing one fails, and so does saving
// any change to a contact that has (or ever had) a note -- Cocoa error 134092. The
// address book's database is off limits too without Full Disk Access. So notes, and
// edits to contacts with notes, go through Contacts.app's AppleScript. The first
// time, macOS asks to let PIM Bridge control Contacts.

let contactsAppID = "com.apple.AddressBook"

func scriptString(_ s: String) -> String {
    "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

var launchedContacts = false         // we started Contacts.app, so we quit it
var quitContactsLater: DispatchWorkItem?

/// Runs AppleScript lines inside `tell application "Contacts"`. If Contacts.app isn't
/// running it is started hidden, and quit again a minute after the last script --
/// unless someone has brought it to the screen in the meantime.
@discardableResult
func runContactsScript(_ lines: [String]) throws -> NSAppleEventDescriptor {
    quitContactsLater?.cancel()
    if NSRunningApplication.runningApplications(withBundleIdentifier: contactsAppID).isEmpty,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: contactsAppID) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        let started = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in started.signal() }
        _ = started.wait(timeout: .now() + 15)
        launchedContacts = true
    }
    defer {
        if launchedContacts {
            let quit = DispatchWorkItem {
                launchedContacts = false
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: contactsAppID)
                where app.isHidden && !app.isActive {
                    app.terminate()
                }
            }
            quitContactsLater = quit
            work.asyncAfter(deadline: .now() + 60, execute: quit)
        }
    }
    let source = (["tell application id \"\(contactsAppID)\""] + lines + ["end tell"]).joined(separator: "\n")
    // On the main thread: with the main run loop running, the reply goes there, and a
    // script run anywhere else waits for it until the AppleEvent times out.
    var error: NSDictionary?
    let result = DispatchQueue.main.sync { NSAppleScript(source: source)?.executeAndReturnError(&error) }
    if let error = error {
        throw ToolError(message: "Contacts.app: \(error[NSAppleScript.errorMessage] ?? error). If that's a permission "
                        + "error, allow PIM Bridge to control Contacts in System Settings → Privacy & Security → Automation.")
    }
    return result ?? NSAppleEventDescriptor.null()
}

var notes: [String: String] = [:]  // by CNContact.identifier
var notesToken: Data?               // the store's history token when notes was read

/// Reads every note through Contacts.app, but only when the address book changed
/// since the last read. On failure, contacts read without notes.
func loadNotes() {
    let token = contactStore.currentHistoryToken
    if token != nil && token == notesToken { return }
    do {
        let both = try runContactsScript(["get {id, note} of every person"])
        guard both.numberOfItems == 2, let ids = both.atIndex(1), let texts = both.atIndex(2) else { return }
        var found: [String: String] = [:]
        if ids.numberOfItems > 0 {
            for i in 1...ids.numberOfItems {
                if let id = ids.atIndex(i)?.stringValue, let text = texts.atIndex(i)?.stringValue, !text.isEmpty {
                    found[id] = text
                }
            }
        }
        notes = found
        notesToken = token
    } catch {
        log("can't read notes: \((error as? ToolError)?.message ?? "\(error)")")
    }
}

func allContacts() throws -> [CNContact] {
    var out: [CNContact] = []
    try contactStore.enumerateContacts(with: CNContactFetchRequest(keysToFetch: contactKeys)) { c, _ in out.append(c) }
    loadNotes()
    return out
}

func reread(_ identifier: String) throws -> CNContact {
    loadNotes()
    return try contactStore.unifiedContact(withIdentifier: identifier, keysToFetch: contactKeys)
}

func contactID(_ c: CNContact) -> String {
    Insecure.SHA1.hash(data: Data(c.identifier.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8).lowercased()
}

func note(_ c: CNContact) -> String { notes[c.identifier] ?? "" }

func label(_ raw: String?, _ fallback: String) -> String {
    guard let raw = raw, !raw.isEmpty else { return fallback }
    return CNLabeledValue<NSString>.localizedString(forLabel: raw)
}

func isCompany(_ c: CNContact) -> Bool { c.contactType == .organization }

func displayName(_ c: CNContact) -> String {
    if isCompany(c) && !c.organizationName.isEmpty { return c.organizationName }
    if let full = CNContactFormatter.string(from: c, style: .fullName), !full.isEmpty { return full }
    let joined = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
    return joined.isEmpty ? (c.organizationName.isEmpty ? "(no name)" : c.organizationName) : joined
}

func addressText(_ a: CNPostalAddress) -> String {
    let region = [a.state, a.postalCode].filter { !$0.isEmpty }.joined(separator: " ")
    return [a.street.replacingOccurrences(of: "\n", with: ", "), a.city, region, a.country]
        .filter { !$0.isEmpty }.joined(separator: ", ")
}

func birthdayText(_ c: CNContact) -> String {
    guard let b = c.birthday, let month = b.month, let day = b.day else { return "" }
    let name = formatter("MMMM").monthSymbols[month - 1]
    return b.year.map { "\(name) \(day), \($0)" } ?? "\(name) \(day)"
}

func digits(_ text: String) -> String { text.filter(\.isNumber) }

func sameNumber(_ a: String, _ b: String) -> Bool {
    let (x, y) = (digits(a), digits(b))
    if x.count < 7 || y.count < 7 { return x == y && !x.isEmpty }
    return x.suffix(10) == y.suffix(10)
}

func haystack(_ c: CNContact) -> String {
    ([displayName(c), c.givenName, c.familyName, c.nickname, c.organizationName, c.departmentName, c.jobTitle, note(c)]
     + c.emailAddresses.map { $0.value as String } + c.contactRelations.map { $0.value.name })
        .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
}

func matches(_ c: CNContact, _ query: String) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty { return true }
    let d = digits(q)
    if d.count >= 3, q.range(of: #"^[\d\s().+-]+$"#, options: .regularExpression) != nil {
        return c.phoneNumbers.contains { digits($0.value.stringValue).contains(d.suffix(10)) }
    }
    let hay = haystack(c)
    return q.lowercased().split(separator: " ").allSatisfy { hay.contains($0) }
}

func sortKey(_ c: CNContact) -> (String, String) {
    ((c.givenName.isEmpty ? displayName(c) : c.givenName).lowercased(), c.familyName.lowercased())
}

func sorted(_ cs: [CNContact]) -> [CNContact] { cs.sorted { sortKey($0) < sortKey($1) } }

func contactLine(_ c: CNContact) -> String {
    var name = displayName(c)
    if !c.organizationName.isEmpty && !isCompany(c) && c.organizationName != name { name += " (\(c.organizationName))" }
    let bits = c.phoneNumbers.prefix(2).map { $0.value.stringValue } + c.emailAddresses.prefix(1).map { $0.value as String }
    return "\(contactID(c))  \(name)" + (bits.isEmpty ? "" : "  " + bits.joined(separator: "  "))
}

func contactText(_ c: CNContact) -> String {
    var out = ["\(displayName(c))  \(contactID(c))"]
    let role = [c.jobTitle, c.departmentName, c.organizationName != displayName(c) ? c.organizationName : ""]
        .filter { !$0.isEmpty }.joined(separator: ", ")
    if !role.isEmpty { out.append("  \(role)") }
    if !c.nickname.isEmpty { out.append("  \"\(c.nickname)\"") }
    var rows: [(String, String)] = []
    rows += c.phoneNumbers.map { (label($0.label, "phone"), $0.value.stringValue) }
    rows += c.emailAddresses.map { (label($0.label, "email"), $0.value as String) }
    rows += c.postalAddresses.map { (label($0.label, "address"), addressText($0.value)) }
    rows += c.urlAddresses.map { (label($0.label, "url"), $0.value as String) }
    if !birthdayText(c).isEmpty { rows.append(("birthday", birthdayText(c))) }
    rows += c.contactRelations.map { (label($0.label, "related"), $0.value.name) }
    let width = max(4, rows.map { $0.0.count }.max() ?? 0)
    out += rows.map { "  \(pad($0.0, width))  \($0.1)" }
    if !note(c).isEmpty {
        out.append("  \(pad("note", width))  " + note(c).replacingOccurrences(of: "\n", with: "\n  " + String(repeating: " ", count: width + 2)))
    }
    return out.joined(separator: "\n")
}

/// One contact by short id, email, phone number or name.
func findContact(_ cs: [CNContact], _ raw: String) throws -> CNContact {
    let ref = raw.trimmingCharacters(in: .whitespaces)
    guard !ref.isEmpty else { throw ToolError(message: "Which contact?") }
    var hits = cs.filter { contactID($0) == ref.lowercased() }
    if hits.isEmpty && ref.contains("@") {
        hits = cs.filter { $0.emailAddresses.contains { ($0.value as String).lowercased() == ref.lowercased() } }
    }
    if hits.isEmpty && ref.range(of: #"^\+?[\d\s().-]{7,}$"#, options: .regularExpression) != nil {
        hits = cs.filter { $0.phoneNumbers.contains { sameNumber($0.value.stringValue, ref) } }
    }
    if hits.isEmpty { hits = cs.filter { displayName($0).lowercased() == ref.lowercased() } }
    if hits.isEmpty {
        hits = cs.filter { c in
            let names = (displayName(c) + " " + c.organizationName).lowercased()
            return ref.lowercased().split(separator: " ").allSatisfy { names.contains($0) }
        }
    }
    if hits.isEmpty { throw ToolError(message: "No contact matches \"\(ref)\"") }
    if hits.count > 1 {
        throw ToolError(message: "\"\(ref)\" matches \(hits.count) contacts; use an id:\n"
                        + sorted(hits).prefix(15).map { "  " + contactLine($0) }.joined(separator: "\n"))
    }
    return hits[0]
}

// MARK: - Writing

/// "work:(423) 555-0100" -> ("work", "(423) 555-0100"); URLs keep their scheme.
func splitLabel(_ text: String, _ fallback: String) -> (String, String) {
    let pattern = try! NSRegularExpression(pattern: #"^\s*([A-Za-z][\w .'-]{0,24}?)\s*:\s*(.+)$"#)
    if let m = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
        let value = (text as NSString).substring(with: m.range(at: 2))
        if !value.hasPrefix("//") {
            return ((text as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces),
                    value.trimmingCharacters(in: .whitespaces))
        }
    }
    return (fallback, text.trimmingCharacters(in: .whitespaces))
}

let phoneLabels = ["mobile": CNLabelPhoneNumberMobile, "cell": CNLabelPhoneNumberMobile, "iphone": CNLabelPhoneNumberiPhone,
                   "home": CNLabelHome, "work": CNLabelWork, "main": CNLabelPhoneNumberMain, "other": CNLabelOther,
                   "pager": CNLabelPhoneNumberPager, "home fax": CNLabelPhoneNumberHomeFax,
                   "work fax": CNLabelPhoneNumberWorkFax, "fax": CNLabelPhoneNumberOtherFax]
let emailLabels = ["home": CNLabelHome, "work": CNLabelWork, "other": CNLabelOther, "icloud": CNLabelEmailiCloud,
                   "school": CNLabelSchool]
let addressLabels = ["home": CNLabelHome, "work": CNLabelWork, "other": CNLabelOther, "school": CNLabelSchool]
let urlLabels = ["homepage": CNLabelURLAddressHomePage, "home": CNLabelHome, "work": CNLabelWork, "other": CNLabelOther,
                 "school": CNLabelSchool]

/// A standard label's constant, or the word itself as a custom label.
func labelValue(_ word: String, _ table: [String: String]) -> String { table[word.lowercased()] ?? word }

/// "123 Main St, Chattanooga, TN 37402[, USA]"
func parseAddress(_ text: String) -> CNPostalAddress {
    let a = CNMutablePostalAddress()
    var parts = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    if parts.count >= 4, parts.last!.rangeOfCharacter(from: .decimalDigits) == nil { a.country = parts.removeLast() }
    guard parts.count >= 3 else {
        a.street = text.trimmingCharacters(in: .whitespaces)
        return a
    }
    let last = parts.removeLast()
    if let r = last.range(of: #"\s*\d{5}(-\d{4})?$"#, options: .regularExpression) {
        a.postalCode = last[r].trimmingCharacters(in: .whitespaces)
        a.state = String(last[..<r.lowerBound])
    } else {
        a.state = last
    }
    a.city = parts.removeLast()
    a.street = parts.joined(separator: ", ")
    return a
}

func parseBirthday(_ raw: String) throws -> DateComponents {
    let text = raw.trimmingCharacters(in: .whitespaces)
    let numbers = text.split(whereSeparator: { "-/".contains($0) }).compactMap { Int($0) }
    var c = DateComponents()
    c.calendar = Calendar(identifier: .gregorian)
    if numbers.count == 3, text.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
        (c.year, c.month, c.day) = (numbers[0], numbers[1], numbers[2])
    } else if numbers.count == 2, text.range(of: #"^\d{1,2}[-/]\d{1,2}$"#, options: .regularExpression) != nil {
        (c.month, c.day) = (numbers[0], numbers[1])
    } else {
        throw ToolError(message: "Birthday \"\(raw)\": use YYYY-MM-DD, or MM-DD without a year")
    }
    var check = c
    check.year = check.year ?? 2000
    guard check.isValidDate else { throw ToolError(message: "Birthday \"\(raw)\" isn't a real date") }
    c.calendar = nil
    return c
}

func splitName(_ name: String) -> (String, String) {
    let words = name.split(separator: " ").map(String.init)
    if words.count <= 1 { return (words.first ?? "", "") }
    return (words.dropLast().joined(separator: " "), words.last!)
}

func strings(_ args: [String: Any], _ key: String) -> [String] { args[key] as? [String] ?? [] }

func addItems(_ c: CNMutableContact, _ args: [String: Any], prefix: String) throws {
    for p in strings(args, prefix + "phones") {
        let (word, number) = splitLabel(p, "mobile")
        guard !digits(number).isEmpty else { throw ToolError(message: "\"\(p)\" isn't a phone number") }
        c.phoneNumbers.append(CNLabeledValue(label: labelValue(word, phoneLabels), value: CNPhoneNumber(stringValue: number)))
    }
    for e in strings(args, prefix + "emails") {
        let (word, address) = splitLabel(e, "home")
        guard address.contains("@") else { throw ToolError(message: "\"\(e)\" isn't an email address") }
        c.emailAddresses.append(CNLabeledValue(label: labelValue(word, emailLabels), value: address as NSString))
    }
    for a in strings(args, prefix + "addresses") {
        let (word, text) = splitLabel(a, "home")
        c.postalAddresses.append(CNLabeledValue(label: labelValue(word, addressLabels), value: parseAddress(text)))
    }
    for u in strings(args, prefix + "urls") {
        let (word, url) = splitLabel(u, "homepage")
        c.urlAddresses.append(CNLabeledValue(label: labelValue(word, urlLabels), value: url as NSString))
    }
}

func removeItems(_ c: CNMutableContact, _ args: [String: Any]) throws {
    let name = displayName(c)
    for p in strings(args, "remove_phones") {
        let keep = c.phoneNumbers.filter { !sameNumber($0.value.stringValue, p) }
        if keep.count == c.phoneNumbers.count { throw ToolError(message: "\(name) has no phone number \(p)") }
        c.phoneNumbers = keep
    }
    for e in strings(args, "remove_emails") {
        let keep = c.emailAddresses.filter { ($0.value as String).lowercased() != e.trimmingCharacters(in: .whitespaces).lowercased() }
        if keep.count == c.emailAddresses.count { throw ToolError(message: "\(name) has no email \(e)") }
        c.emailAddresses = keep
    }
    for text in strings(args, "remove_addresses") {
        let hits = c.postalAddresses.filter { addressText($0.value).lowercased().contains(text.lowercased()) }
        guard hits.count == 1 else { throw ToolError(message: "\"\(text)\" matches \(hits.count) of \(name)'s addresses") }
        c.postalAddresses = c.postalAddresses.filter { $0 !== hits[0] }
    }
    for u in strings(args, "remove_urls") {
        let hits = c.urlAddresses.filter { ($0.value as String).lowercased().contains(u.lowercased()) }
        guard hits.count == 1 else { throw ToolError(message: "\"\(u)\" matches \(hits.count) of \(name)'s URLs") }
        c.urlAddresses = c.urlAddresses.filter { $0 !== hits[0] }
    }
}

func writeNote(_ identifier: String, _ text: String) throws {
    try runContactsScript(["set p to person id \(scriptString(identifier))",
                           text.isEmpty ? "set note of p to missing value" : "set note of p to \(scriptString(text))",
                           "save"])
}

/// AppleScript's label for a phone, email, address or URL label word.
func scriptLabel(_ word: String) -> String {
    switch word.lowercased() {
    case "iphone": return "iPhone"
    case "icloud": return "iCloud"
    case "cell": return "mobile"
    case "fax": return "other fax"
    default: return word
    }
}

/// The same edit as updateContact, done through Contacts.app, for contacts the
/// framework can't save. The arguments were already checked against `c`.
func updateThroughContactsApp(_ found: CNContact, _ c: CNMutableContact, _ args: [String: Any]) throws {
    var lines = ["set p to person id \(scriptString(found.identifier))"]
    func set(_ property: String, _ value: String) {
        lines.append("set \(property) of p to " + (value.isEmpty ? "missing value" : scriptString(value)))
    }
    if c.givenName != found.givenName { set("first name", c.givenName) }
    if c.familyName != found.familyName { set("last name", c.familyName) }
    if c.organizationName != found.organizationName { set("organization", c.organizationName) }
    if c.contactType != found.contactType { lines.append("set company of p to \(c.contactType == .organization)") }
    if c.jobTitle != found.jobTitle { set("job title", c.jobTitle) }
    if c.nickname != found.nickname { set("nickname", c.nickname) }
    if let text = args["note"] as? String { set("note", text) }
    if args["birthday"] != nil {
        if let b = c.birthday, let month = b.month, let day = b.day {
            guard let year = b.year else {
                throw ToolError(message: "This contact has a note, so it's changed through Contacts.app, which can't set "
                                + "a birthday without a year. Give the year, or set it in Contacts.")
            }
            lines += ["set d to current date", "set time of d to 43200", "set day of d to 1", "set year of d to \(year)",
                      "set month of d to \(month)", "set day of d to \(day)", "set birth date of p to d"]
        } else {
            lines.append("set birth date of p to missing value")
        }
    }
    let gone = { (old: [String], new: [String]) in old.filter { !new.contains($0) } }
    for value in gone(found.phoneNumbers.map { $0.value.stringValue }, c.phoneNumbers.map { $0.value.stringValue }) {
        lines.append("delete (every phone of p whose value is \(scriptString(value)))")
    }
    for value in gone(found.emailAddresses.map { $0.value as String }, c.emailAddresses.map { $0.value as String }) {
        lines.append("delete (every email of p whose value is \(scriptString(value)))")
    }
    for value in gone(found.urlAddresses.map { $0.value as String }, c.urlAddresses.map { $0.value as String }) {
        lines.append("delete (every url of p whose value is \(scriptString(value)))")
    }
    let kept = Set(c.postalAddresses.map { $0.identifier })
    for a in found.postalAddresses where !kept.contains(a.identifier) {
        lines.append("delete (every address of p whose street is \(scriptString(a.value.street)) and city is \(scriptString(a.value.city)))")
    }
    for p in strings(args, "add_phones") {
        let (word, number) = splitLabel(p, "mobile")
        lines.append("make new phone at end of phones of p with properties {label:\(scriptString(scriptLabel(word))), value:\(scriptString(number))}")
    }
    for e in strings(args, "add_emails") {
        let (word, address) = splitLabel(e, "home")
        lines.append("make new email at end of emails of p with properties {label:\(scriptString(scriptLabel(word))), value:\(scriptString(address))}")
    }
    for u in strings(args, "add_urls") {
        let (word, url) = splitLabel(u, "homepage")
        lines.append("make new url at end of urls of p with properties {label:\(scriptString(scriptLabel(word))), value:\(scriptString(url))}")
    }
    for text in strings(args, "add_addresses") {
        let (word, rest) = splitLabel(text, "home")
        let a = parseAddress(rest)
        lines.append("make new address at end of addresses of p with properties {label:\(scriptString(scriptLabel(word))), "
                     + "street:\(scriptString(a.street)), city:\(scriptString(a.city)), state:\(scriptString(a.state)), "
                     + "zip:\(scriptString(a.postalCode)), country:\(scriptString(a.country))}")
    }
    lines.append("save")
    try runContactsScript(lines)
}

func searchContacts(_ args: [String: Any]) throws -> Any {
    let query = args["query"] as? String ?? ""
    let found = sorted(try allContacts().filter { matches($0, query) })
    if found.isEmpty { return query.isEmpty ? "No contacts." : "No contacts match “\(query)”." }
    let limit = max(1, args["limit"] as? Int ?? 50)
    return found.prefix(limit).map(contactLine).joined(separator: "\n")
        + (found.count > limit ? "\n… and \(found.count - limit) more" : "")
}

func getContact(_ args: [String: Any]) throws -> Any {
    contactText(try findContact(try allContacts(), args["contact"] as? String ?? ""))
}

func createContact(_ args: [String: Any]) throws -> Any {
    let name = args["name"] as? String ?? ""
    if !name.isEmpty && (args["first"] != nil || args["last"] != nil) {
        throw ToolError(message: "Give name or first/last, not both")
    }
    var (first, last) = splitName(name)
    if args["first"] != nil || args["last"] != nil { (first, last) = (args["first"] as? String ?? "", args["last"] as? String ?? "") }
    let company = args["company"] as? String ?? ""
    guard !(first + last + company).isEmpty else { throw ToolError(message: "A contact needs a name or a company") }
    let existing = try allContacts()
    if args["force"] as? Bool != true {
        let phones = strings(args, "phones").map { splitLabel($0, "").1 }
        let emails = strings(args, "emails").map { splitLabel($0, "").1.lowercased() }
        let same = existing.filter { c in
            c.phoneNumbers.contains { n in phones.contains { sameNumber(n.value.stringValue, $0) } }
                || c.emailAddresses.contains { emails.contains(($0.value as String).lowercased()) }
        }
        if !same.isEmpty {
            throw ToolError(message: "That phone or email is already on:\n" + same.map { "  " + contactLine($0) }.joined(separator: "\n")
                            + "\nUpdate that contact instead, or pass force=true to add anyway")
        }
    }
    let c = CNMutableContact()
    c.givenName = first
    c.familyName = last
    c.organizationName = company
    if first.isEmpty && last.isEmpty { c.contactType = .organization }
    c.jobTitle = args["title"] as? String ?? ""
    c.nickname = args["nickname"] as? String ?? ""
    if let text = args["birthday"] as? String, !text.isEmpty { c.birthday = try parseBirthday(text) }
    try addItems(c, args, prefix: "")
    let request = CNSaveRequest()
    request.add(c, toContainerWithIdentifier: nil)
    try contactStore.execute(request)
    if let text = args["note"] as? String, !text.isEmpty { try writeNote(c.identifier, text) }
    return "added:\n" + contactText(try reread(c.identifier))
}

func updateContact(_ args: [String: Any]) throws -> Any {
    let found = try findContact(try allContacts(), args["contact"] as? String ?? "")
    guard let c = found.mutableCopy() as? CNMutableContact else { throw ToolError(message: "Can't edit that contact") }
    if args["name"] != nil && (args["first"] != nil || args["last"] != nil) {
        throw ToolError(message: "Give name or first/last, not both")
    }
    if let company = args["company"] as? String {
        c.organizationName = company
        if company.isEmpty && isCompany(c) { c.contactType = .person }
    }
    if let name = args["name"] as? String { (c.givenName, c.familyName) = splitName(name) }
    if let first = args["first"] as? String { c.givenName = first }
    if let last = args["last"] as? String { c.familyName = last }
    if let title = args["title"] as? String { c.jobTitle = title }
    if let nickname = args["nickname"] as? String { c.nickname = nickname }
    if let text = args["birthday"] as? String { c.birthday = text.isEmpty ? nil : try parseBirthday(text) }
    try removeItems(c, args)
    try addItems(c, args, prefix: "add_")
    if (c.givenName + c.familyName + c.organizationName).trimmingCharacters(in: .whitespaces).isEmpty {
        throw ToolError(message: "That would leave the contact with no name or company")
    }
    let request = CNSaveRequest()
    request.update(c)
    do {
        try contactStore.execute(request)
        if let text = args["note"] as? String { try writeNote(c.identifier, text) }
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == 134092 {
        try updateThroughContactsApp(found, c, args)
    }
    return "updated:\n" + contactText(try reread(c.identifier))
}

func deleteContact(_ args: [String: Any]) throws -> Any {
    let found = try findContact(try allContacts(), args["contact"] as? String ?? "")
    guard let c = found.mutableCopy() as? CNMutableContact else { throw ToolError(message: "Can't delete that contact") }
    let summary = contactLine(found)
    let request = CNSaveRequest()
    request.delete(c)
    try contactStore.execute(request)
    return "deleted \(summary)"
}

// MARK: - Tools

let contactProperty: [String: Any] = ["type": "string", "description": "8-character contact id, or a name, phone number or email"]

func labelledList(_ what: String, _ example: String) -> [String: Any] {
    ["type": "array", "items": ["type": "string"], "description": "\(what), each optionally prefixed with a label, e.g. \(example)"]
}

let phonesProperty = labelledList("Phone numbers", "\"(423) 555-0100\" (mobile) or \"work:(423) 555-0100\"")
let emailsProperty = labelledList("Email addresses", "\"a@b.com\" (home) or \"work:a@b.com\"")
let addressesProperty = labelledList("Postal addresses", "\"home:123 Main St, Chattanooga, TN 37402\"")
let urlsProperty = labelledList("Web addresses", "\"https://example.com\" (homepage)")
let birthdayProperty: [String: Any] = ["type": "string", "description": "YYYY-MM-DD, or MM-DD when the year isn't known"]
func clearable(_ what: String) -> [String: Any] { ["type": "string", "description": "\(what); \"\" clears it"] }
let stringList: [String: Any] = ["type": "array", "items": ["type": "string"]]

let contactTools: [Tool] = [
    Tool(name: "search_contacts",
         description: "Find contacts whose name, company, title, nickname, email, related names or notes contain every word "
             + "of the query, or whose phone number contains the digits. An empty query lists everyone.",
         schema: schema(["query": ["type": "string"], "limit": ["type": "integer", "default": 50]]),
         readOnly: true, destructive: false, run: searchContacts),
    Tool(name: "get_contact",
         description: "One contact in full: every phone, email, address, URL, birthday, related name and the notes.",
         schema: schema(["contact": contactProperty], required: ["contact"]), readOnly: true, destructive: false, run: getContact),
    Tool(name: "create_contact",
         description: "Create a contact. Give name (split into first/last at the last space) or first/last; company alone "
             + "makes a company card. Refuses when a phone or email is already on another contact unless force=true; "
             + "prefer update_contact then.",
         schema: schema(["name": ["type": "string"], "first": ["type": "string"], "last": ["type": "string"],
                         "company": ["type": "string"], "title": ["type": "string"], "nickname": ["type": "string"],
                         "phones": phonesProperty, "emails": emailsProperty, "addresses": addressesProperty, "urls": urlsProperty,
                         "note": ["type": "string"], "birthday": birthdayProperty,
                         "force": ["type": "boolean", "default": false]]),
         readOnly: false, destructive: false, run: createContact),
    Tool(name: "update_contact",
         description: "Change a contact: only the fields given change. add_* fields add entries; remove_* fields remove "
             + "matching ones (phones by number, emails by address, addresses and URLs by a unique part of their text).",
         schema: schema(["contact": contactProperty, "name": ["type": "string", "description": "First and last together"],
                         "first": ["type": "string"], "last": ["type": "string"],
                         "company": clearable("Company"), "title": clearable("Job title"), "nickname": clearable("Nickname"),
                         "note": clearable("Notes (replaces them)"),
                         "birthday": ["type": "string", "description": "YYYY-MM-DD, or MM-DD when the year isn't known; \"\" clears it"],
                         "add_phones": phonesProperty, "add_emails": emailsProperty, "add_addresses": addressesProperty,
                         "add_urls": urlsProperty, "remove_phones": stringList, "remove_emails": stringList,
                         "remove_addresses": stringList, "remove_urls": stringList], required: ["contact"]),
         readOnly: false, destructive: false, run: updateContact),
    Tool(name: "delete_contact", description: "Delete a contact from iCloud (and so from every device).",
         schema: schema(["contact": contactProperty], required: ["contact"]), readOnly: false, destructive: true, run: deleteContact),
]

let contactInstructions = """
Ian's contacts, read on his Mac (his iCloud address book, the same one as his iPhone). Contact ids \
are the 8-character ids printed next to each contact; a name, phone number or email also works. \
Creating, changing or deleting contacts changes Ian's real address book on all his devices: only do \
it when Ian asked for that specific change, and say what you did afterwards.
"""

let contactsServer = Server(
    name: "contacts", instructions: contactInstructions, tools: contactTools,
    accessProblem: {
        contactsAccess() == "fullAccess" ? nil : "Contacts access is \(contactsAccess()) on the Mac. Allow PIM Bridge in "
            + "System Settings → Privacy & Security → Contacts."
    },
    prepare: {})

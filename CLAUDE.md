# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

PIM Bridge exposes Apple Reminders, Calendar, Contacts and Gmail to agents on this Mac. Two parts:

- `mac/`: a Swift app (no Xcode project, no SwiftPM) that runs as a LaunchAgent and serves four MCP
  servers on `127.0.0.1:8765`: `/reminders/mcp`, `/calendar/mcp`, `/contacts/mcp`, `/gmail/mcp`, plus
  `/health`. MenuWidgets (~/Code/mac-menu-widgets) reaches Gmail over a Unix socket instead.
- `cli/pim`: one Python 3.9 script, stdlib only. `~/.local/bin/{pim,reminders,calendar,contacts,gmail}` are
  symlinks to it, and it dispatches on `argv[0]`. Each name is a thin client that calls the same MCP
  tools over HTTP, so editing `cli/pim` takes effect immediately.

README.md covers the design rationale, security model and the Contacts notes workaround in more detail.

## Commands

```bash
# Typecheck only (fast, touches nothing installed)
cd mac && xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macos14.0 \
  Common.swift Reminders.swift Calendar.swift Contacts.swift Gmail.swift Socket.swift main.swift

mac/install.sh                                  # build, sign, install to ~/Applications, restart the LaunchAgent
launchctl kickstart -k gui/$(id -u)/com.ianneub.pim-bridge   # restart without rebuilding
tail -f ~/Library/Logs/PIMBridge.log

# Call one MCP tool directly through the CLI
reminders tool list_reminders '{"status":"incomplete"}'
calendar tool list_events '{}'
```

A new Swift file must be added to the `swiftc` line in `mac/install.sh` (and the typecheck command).
The LaunchAgent plist is a template: `install.sh` substitutes `@HOME@`. `PB_DEFAULT_CALENDAR` (in the
plist) and `PB_PORT` are the only env settings; `PIM_BRIDGE_URL` overrides the CLI's target.

There is no automated test suite. Testing is manual against the real stores (Ian's live iCloud data,
shared with family): use throwaway items prefixed "ZZ" and delete them afterwards, and ask before
creating, changing or deleting anything.

`install.sh` signs with the "MouseRemap Local Signing" identity if present; otherwise it signs ad hoc
and macOS re-prompts for all four permissions (Reminders, Calendars, Contacts, Automation → Contacts)
after every rebuild.

## Architecture

- `main.swift`: a hand-rolled HTTP/1.1 server on `Network.framework` (one request per connection,
  `Connection: close`) and a stateless MCP JSON-RPC handler: one JSON object per POST, one JSON reply
  or 202 for notifications; no sessions, no SSE, no batching. Auth runs on every path: bearer token
  (constant-time compare), refusing any browser `Origin` and any non-loopback `Host`.
- `Common.swift`: the `Tool` / `Server` structs, the `schema()` helper, logging, and `parseWhen` /
  `parseDuration`. All date input from both the MCP tools and the CLI goes through `parseWhen` (ISO
  formats first, then keywords, relative durations, then `NSDataDetector`, rejecting leftover words).
- `Reminders.swift`, `Calendar.swift`, `Contacts.swift`, `Gmail.swift`: each ends by defining a `Server`
  (tools, instructions string, `accessProblem`, `prepare`, `queue`), registered in the `servers` map in
  `main.swift`.
- `Socket.swift`: `bridge.sock`, line-delimited JSON-RPC for the Gmail server, open only to MenuWidgets
  (audit token + code requirement pinned to this app's own certificate, hardened runtime required).
  Calls from it run with `currentCaller == .menuBar`; everything else is `.http`.
  `store` (the shared `EKEventStore`) lives in `Reminders.swift` and is used by Calendar too.

Concurrency: all EventKit and Contacts work runs serially on the `work` queue; Gmail runs on the
concurrent `gmailQueue` (shared state under `gmailLock`); networking is on `netQueue`. The main thread runs a real `RunLoop` (not `dispatchMain`) because NSWorkspace and
AppleScript need it: `runContactsScript` hops to `DispatchQueue.main.sync`, since an AppleEvent reply
is delivered to the main run loop and a script on another thread hangs until timeout.

Non-obvious constraints:

- **Tool names and arguments must stay compatible** with the older `reminders-bridge`,
  `calendar-cli` and `contacts-cli` tools this replaced, so agents behave the same. The `instructions`
  string on each `Server` is what agents see as server instructions.
- **Reminder URLs** come from the private ReminderKit framework (`dlopen` + `NSClassFromString`),
  because the URL Reminders.app shows is an attachment EventKit doesn't expose. Selectors are checked
  before every call so an OS change degrades only the URL field, never crashes the process.
- **Calendar event ids** are the first 8 hex chars of a SHA1 of the event id (plus occurrence date for
  repeating events). `shortID()` records each id it prints in
  `~/Library/Application Support/PIMBridge/event-ids.json`; `findEvent` only resolves ids that were
  listed before. Call `shortID()` whenever an event id is shown.
- **Contact notes**: the Contacts framework hides notes without an Apple-only entitlement and refuses to
  save any change to a contact that has (or had) a note (Cocoa error 134092). Notes are read via
  Contacts.app AppleScript (cached until the store's history token changes), and such edits fall back to
  `updateThroughContactsApp`. Contacts.app is launched hidden on demand and quit a minute after last use.
- `prepare` for Reminders/Calendar calls `store.reset()` before each tool call so changes from other
  devices are visible.
- **Gmail safety rules** (settled with Ian): no send, draft-delete or permanent-delete tool ever;
  trash over HTTP needs Touch ID (biometrics only, no password fallback) with a prompt the bridge
  writes; only the socket skips it. Refresh tokens go through SecItem, never `/usr/bin/security`.
  The app is signed with the hardened runtime (`PIMBridge.entitlements`) so nothing can inject code
  and read those tokens. Ids go through `gmailID()` before they're put in a URL path.

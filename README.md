# PIM Bridge

Apple Reminders, Calendar and Contacts for Claude Code and other agents on this Mac.

- `mac/`: a small Swift app that runs as a LaunchAgent and serves three MCP servers
  (Streamable HTTP, stateless JSON) on 127.0.0.1:8765:
  `/reminders/mcp`, `/calendar/mcp`, `/contacts/mcp`.
- `cli/pim`: one Python script (system Python 3.9 is enough), installed as
  `reminders`, `calendar` and `contacts` in `~/.local/bin`. Each calls the same tools
  the agents get, for agents without MCP, scripts, and terminal use.

It replaces three Omarchy-era tools: `reminders-bridge` (the Reminders code moved here
unchanged apart from date parsing), and the EDS-based `calendar-cli` and `contacts-cli`.
The tool names and arguments match theirs, so agents behave the same way.

## Why an app

macOS grants Reminders, Calendars and Contacts access to a process's *responsible
app*. A CLI run from Ghostty would get them from Ghostty, so everything in a terminal
would have them. This app holds the three permissions itself, and everything else
talks to it over HTTP with a token.

## Using it

Claude Code (user scope; already set up):

```bash
for n in reminders calendar contacts; do
  claude mcp add-json -s user $n "{\"type\":\"http\",\"url\":\"http://127.0.0.1:8765/$n/mcp\",\"headersHelper\":\"$HOME/.local/bin/pim auth-header\"}"
done
```

Other MCP clients: the same URLs, with the header `Authorization: Bearer <token>`
(`pim auth-header` prints it). Codex, for example, takes `bearer_token_env_var`.

CLI: `reminders --help`, `calendar --help`, `contacts --help`. Dates take ISO
("2026-10-12 14:00") or English ("tomorrow 3pm", "next fri", "in 2 hours"). The bridge
parses them, with NSDataDetector, so the CLI and MCP tools accept the same things.

## Calendar

Every calendar account in System Settings → Internet Accounts / Calendar.app shows
up: iCloud, both Google accounts, subscriptions. New events go to `PB_DEFAULT_CALENDAR`
in the LaunchAgent plist ("Ian"), else Calendar.app's default calendar.

Event ids are 8 hex characters: a hash of the event id (plus the occurrence's original
date for a repeating event). The bridge remembers which event each id belongs to in
`~/Library/Application Support/PIMBridge/event-ids.json`, so an id must have been
listed before it can be used. Moving a series' time changes its occurrences' ids, as
before. A repeating event can't be moved to another calendar (EventKit can't).

## Contacts and notes

The Contacts framework hides notes from apps without an entitlement Apple only grants
to approved apps. Notes read as empty, writing one fails, and so does saving *any*
change to a contact that has (or ever had) a note: Cocoa error 134092. The address
book database is off limits too without Full Disk Access. So:

- notes are read through Contacts.app's AppleScript (`get {id, note} of every person`),
  cached until the store's history token changes;
- new notes, and every edit to a contact the framework refuses, are made through
  Contacts.app's AppleScript instead. A birthday without a year can't be set that way.

Contacts.app is started hidden when needed and quit a minute after the last use,
unless someone has brought it on screen. The scripts run on the main thread: with the
main run loop running, the AppleEvent reply goes there, and a script on another thread
waits until it times out.

## Security

| Layer | What it stops |
|---|---|
| Listens on 127.0.0.1 only | Every other machine |
| Bearer token, 256 random bits, constant-time compare, on every path | Local processes that can't read the token file |
| Refuses a browser `Origin` and any `Host` other than 127.0.0.1/localhost | Web pages, including through DNS rebinding |
| 60 s connection timeout, 4 MB request cap | Idle or oversized connections piling up |

The token is in `~/Library/Application Support/PIMBridge/token` (0600, directory 0700).
Anything running as Ian that reads it can read and change reminders, calendars and
contacts. That is the point of the bridge, but it's also the whole boundary.

`install.sh` signs with the self-signed "MouseRemap Local Signing" identity when it's
in the login keychain, so the permissions survive rebuilds. Ad hoc signing (the
fallback) means approving all four prompts again after every build.

## Operations

```bash
mac/install.sh                                # build, sign, (re)start the LaunchAgent
launchctl kickstart -k gui/$(id -u)/com.ianneub.pim-bridge
tail -f ~/Library/Logs/PIMBridge.log
curl -s -H "$(pim auth-header | jq -r '"Authorization: " + .Authorization')" http://127.0.0.1:8765/health
```

Rotate the token: delete the token file and kickstart; `pim auth-header` reads the
new one, so no config changes.

Permissions live in System Settings → Privacy & Security → Reminders, Calendars,
Contacts, and Automation (PIM Bridge → Contacts).

## Remote access

Off by design: only processes on this Mac. The Omarchy-era bridge listened on the
Mac's Tailscale address and allowed listed peers (see reminders-bridge's git history);
the same approach would work here if a tailnet machine needs access again. Cloud
agents would need a public HTTPS endpoint with OAuth instead.

## Tests

Tested 2026-10-08 against the real stores, with throwaway "ZZ" items deleted after:
calendar create/edit/all-day/multi-day/series edit/occurrence move/delete on iCloud
"Ian"; reminders create/edit/repeat/URL/complete/delete; contacts create/edit with
labels, address, birthday (with and without year) and notes, the Contacts.app edit
path, the duplicate guard, and delete.

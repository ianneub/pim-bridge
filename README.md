# PIM Bridge

Apple Reminders, Calendar, Contacts and Gmail for Claude Code and other agents on this Mac.

- `mac/`: a small Swift app that runs as a LaunchAgent and serves four MCP servers
  (Streamable HTTP, stateless JSON) on 127.0.0.1:8765:
  `/reminders/mcp`, `/calendar/mcp`, `/contacts/mcp`, `/gmail/mcp`. MenuWidgets
  reaches the Gmail server through a Unix socket instead.
- `cli/pim`: one Python script (system Python 3.9 is enough), installed as
  `reminders`, `calendar`, `contacts` and `gmail` in `~/.local/bin`. Each calls the
  same tools the agents get, for agents without MCP, scripts, and terminal use.

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
for n in reminders calendar contacts gmail; do
  claude mcp add-json -s user $n "{\"type\":\"http\",\"url\":\"http://127.0.0.1:8765/$n/mcp\",\"headersHelper\":\"$HOME/.local/bin/pim auth-header\"}"
done
```

Other MCP clients: the same URLs, with the header `Authorization: Bearer <token>`
(`pim auth-header` prints it). Codex, for example, takes `bearer_token_env_var`.

CLI: `reminders --help`, `calendar --help`, `contacts --help`, `gmail --help`. Dates take ISO
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

## Gmail

Ian's Google Workspace accounts, each with a short name (listed in
`gmail-accounts.json`). The bridge owns the Google sign-in for every client:
Claude Code (MCP), the `gmail` CLI, and MenuWidgets (over the socket). Signing an
account out anywhere signs it out everywhere.

- Scope `gmail.modify`: read, search, create and edit drafts, trash and untrash
  (single messages, or whole threads with `trash_thread`/`untrash_thread`).
  There is no tool that sends, deletes a draft, or deletes permanently. The scope can't
  delete permanently; it *can* send, so "never sends" rests on there being no such tool.
- `update_draft` rewrites a draft in place (`drafts.update`): fields not passed keep
  their values, and the thread and In-Reply-To/References headers are kept. Bodies are
  HTML with a generated plain-text alternative. It refuses a draft with attachments
  (including inline images) rather than drop them. The API doesn't add Gmail's signature.
- Trash over HTTP (CLI, MCP, anything else) always needs **Touch ID**, with no password
  fallback: with the lid closed or after too many failed fingerprints, it fails. The
  prompt says what will happen, e.g. `move 3 emails to Trash in you@example.com:
  "Subject A", "Subject B", "Subject C"`, or for a batch `move 40 emails to Trash in
  you@example.com (32 from notifications@github.com, 8 others)`. It's Touch ID, not a
  dialog, because UI scripting can click dialogs. The bridge can't tell the CLI from an
  agent, so the prompt describes the action, not the caller. Trash from MenuWidgets over
  the socket is one click. Untrash never asks.
- Every trash and untrash is logged with time (UTC), account, message id, sender,
  subject and caller (`menu bar` or `http`) in `gmail-trash-log.jsonl`, kept 90 days
  (`trash_log`, `gmail log`).
- Gmail calls run on their own concurrent queue, so slow Google replies and the
  Touch ID prompt don't hold up Reminders, Calendar or Contacts.

Files in `~/Library/Application Support/PIMBridge` (all 0600):

| File | What |
|---|---|
| `gmail-oauth-client.json` | The Google Cloud "Desktop app" OAuth client, as downloaded |
| `gmail-accounts.json` | The account list (name, email); MenuWidgets shows what `accounts` reports |
| `gmail-trash-log.jsonl` | The trash log |
| `bridge.sock` | MenuWidgets' socket |

Sign in: `gmail sign-in you@example.com Work` (or the `sign_in` tool) opens
the browser and returns at once; `gmail accounts` shows `signed_in` when it's done.
The flow is Google's loopback redirect with PKCE, `login_hint`, offline access, and a
check that the browser signed in the account asked for. When Google rejects a refresh
token (`invalid_grant`), the account shows `needs_sign_in`.

The Google Cloud project is `pim-bridge` (on Ian's personal Google account), with a Desktop
client. It's in **Testing**, with the accounts as test users, because a Workspace
domain blocked the unverified production app asking for `gmail.modify` ("This app is
blocked"). In Testing, Google ends each sign-in after 7 days, so each account needs
signing in again weekly. Going back to production would need each Workspace admin to
mark the client ID as Trusted (Security → API controls → Manage Third-Party App
Access). An Internal app in a project inside each Workspace organization would also
work, with one client per account.

Claude Code: the same `claude mcp add-json` line as the others (above), plus
`"mcp__gmail__trash"` and `"mcp__gmail__trash_thread"` in `permissions.deny` in
`~/.claude/settings.json` as an extra guard. Touch ID is the real one.

### MenuWidgets' socket

`bridge.sock` carries the same JSON-RPC as HTTP, one JSON object per line each way,
on a connection that stays open, and serves only the Gmail server. There's no bearer
token. Before every request the bridge takes the peer's audit token
(`LOCAL_PEERTOKEN`) and checks the process with `SecCodeCheckValidity` against
`identifier "com.ianneub.menu-widgets" and anchor apple generic and certificate
leaf[subject.OU] = "<this app's Team ID>"`, or this app's certificate hash for a
self-signed build.
It also requires the hardened runtime and no `get-task-allow`. Without those, anything
could start the real MenuWidgets with `DYLD_INSERT_LIBRARIES` and use the socket from
inside it. An ad hoc build of the bridge has no certificate to pin, so the socket stays
off.

## Security

| Layer | What it stops |
|---|---|
| Listens on 127.0.0.1 only | Every other machine |
| Bearer token, 256 random bits, constant-time compare, on every path | Local processes that can't read the token file |
| Refuses a browser `Origin` and any `Host` other than 127.0.0.1/localhost | Web pages, including through DNS rebinding |
| 60 s to send a request, 4 MB request cap | Idle or oversized connections piling up |
| Gmail: no send, draft-delete or permanent-delete tool; scope `gmail.modify` | Agents sending mail or destroying it |
| Gmail trash over HTTP needs Touch ID, biometrics only, prompt written by the bridge | Anything with the token trashing mail unseen, including by clicking dialogs |
| Gmail refresh tokens in the login keychain via SecItem, trusted to this app's signature only | Other processes reading a token that could send mail; anything else gets a password prompt |
| Hardened runtime on the bridge | Code loaded into the bridge (`DYLD_INSERT_LIBRARIES`) reading those tokens as PIM Bridge |
| Socket 0600 in a 0700 directory; peer checked by audit token and code signature on every request | Anything but a hardened-runtime MenuWidgets signed by the same Apple team trashing without Touch ID |

The token is in `~/Library/Application Support/PIMBridge/token` (0600, directory 0700).
Anything running as Ian that reads it can read and change reminders, calendars and
contacts. That is the point of the bridge, but it's also the whole boundary.

`install.sh` signs with Ian's **Apple Development** identity: a free Personal Team
certificate (Xcode → Settings → Accounts → Manage Certificates), Team ID `8VKFEEQHSC`.
It also needs Apple's WWDR G3 intermediate in the keychain. Signing uses the hardened
runtime (`PIMBridge.entitlements` allows Calendars, Contacts and Apple Events), and
`PB_SIGN_IDENTITY` overrides the identity. The permissions survive rebuilds, because
they trust the designated requirement (identifier plus Apple Development certificate),
not one build. The Gmail keychain items trust it too, and the login keychain ties them
to the team (`teamid:` partition), so rebuilds don't prompt. With the self-signed
"MouseRemap Local Signing" fallback there's no Team ID: the partition is each build's
`cdhash:`, and the first Gmail call after every rebuild asks for the login password,
once per account. Allow such a prompt only when it names **PIMBridge**; deny any other
app. The certificate renews yearly; the permissions may ask once more then.
Each run, before it first uses a token, the bridge reads the item's access list (no
prompt). If anything besides itself is allowed, which is what "Always Allow" on another
app's prompt does, it logs that and rewrites the item for itself alone. Sign-in always
writes a new item for the same reason. Ad hoc signing (the last fallback) means approving all four prompts again
after every build, and no MenuWidgets socket.

The Gmail tokens are stored with SecItem, not `/usr/bin/security`. An item that
`security` writes trusts `security`, so any process could run `security
find-generic-password -w` and read it without a prompt. The login keychain still
belongs to Ian: Keychain Access, with his login password, can always show them.

Hardening that only Ian can do:

- Set the signing identity's private key (Keychain Access → the "Apple Development: Ian
  Neubert" key → Access Control) to **confirm before every use**, so nothing can
  silently sign a fake MenuWidgets. That means one confirmation per rebuild.
- Keep **Accessibility** permission away from terminals, so nothing can UI-script
  MenuWidgets' Trash button.

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

Gmail: `gmail accounts`, `gmail sign-in EMAIL [NAME]`, `gmail sign-out ACCOUNT`, `gmail
log`. A new OAuth client means replacing `gmail-oauth-client.json` and signing both
accounts in again. Signing out revokes the token at Google and deletes the keychain item
(`com.ianneub.pim-bridge.gmail-token`, account = email).

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

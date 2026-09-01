# YealinkMonitor

A macOS menu bar app that watches Yealink phones through the **YMCS Open API v2**
and tells you when one goes offline.

**[Documentation and screenshots](https://tony-nz.github.io/YealinkMonitor/)** ·
**[Download](https://github.com/tony-nz/YealinkMonitor/releases/latest)**

- Menu bar item showing how many phones need attention, with a popover listing them
- Full window with a sortable, filterable table and a per-device detail pane
- Notifications on confirmed outages and recoveries, with debouncing, quiet hours
  and per-device mutes
- Email alerts over SMTP, batched so one network fault sends one message
- YMCS alarms surfaced next to this app's own view, since a phone can be
  reachable and still have a critical alarm against it
- Accessory health, so a phone with a dead expansion module stops looking fine
- Per-device diagnostics run on the phone: ping, traceroute, system log, config
  file, screenshot and packet capture
- Call quality and the YMCS operation log, in an Activity window
- Restart phones: one, a selection, or everything currently listed — and on a
  schedule
- On-disk history of status changes, so you can see which phones drop repeatedly

## Requirements

- macOS 14 or later
- Swift 6.1 toolchain (Command Line Tools is enough — **Xcode is not required**)
- A YMCS subscription with API access, and a Client ID / Secret

## Getting started

### 1. Verify API access first

Nothing else works until this passes.

```sh
export YMCS_CLIENT_ID='...'
read -rs YMCS_CLIENT_SECRET && export YMCS_CLIENT_SECRET
./Scripts/smoke-test.sh
```

It tries each regional host in turn and reports which one your enterprise is in.

> YMCS issues **one** Client ID/Secret pair per enterprise. Check whether another
> integration already uses them before generating a new pair.

### 2. Build and run

```sh
./Scripts/make-app.sh release run
```

This renders the icon, compiles with SwiftPM, assembles
`build/YealinkMonitor.app` by hand and ad-hoc signs it. Then open **Settings** from the menu bar item, enter the Client
ID and Secret, and press **Save & Test Connection**.

### 3. Look at it without a tenant

```sh
./build/YealinkMonitor.app/Contents/MacOS/YealinkMonitor -demoFleet YES
```

Replaces the live fleet with an invented one: four sites and twenty-six phones
arranged to contain one of everything -- an outage, a handset that never
provisioned, a phone that is online with an unregistered line, a dead expansion
module, firmware drift and an archived spare.

It never creates a monitor, so no request is made and no credential is read. It
substitutes its own settings rather than loading yours, with saving suppressed,
so opening Settings in a demo run cannot show or overwrite your real
configuration, and its history goes to a scratch file. Every screenshot on the
documentation site was taken from it.

### 4. Deploying to another Mac

Release builds are universal (x86_64 + arm64), so the bundle runs natively on
both Intel and Apple Silicon. Build it, copy it over, then provision that
machine once:

```sh
./Scripts/provision.sh --id '<AccessKey ID>' --region au --app /Applications/YealinkMonitor.app
```

It prompts for the secret (or reads `YMCS_CLIENT_SECRET`), stores it in the
login keychain and writes the Client ID and region to the app's preferences.
`--uninstall` reverses both.

Because the app is only ad-hoc signed, Gatekeeper rejects it on a Mac it did not
come from. `provision.sh --app <path>` clears the quarantine flag as part of
provisioning, so running it is usually all that is needed.

On macOS 15 the refusal reads **"YealinkMonitor is damaged and can't be
opened"**, which sounds like a corrupt download and is not: it is what an
ad-hoc signed, quarantined bundle looks like to Gatekeeper. There is no
right-click bypass for that wording, and `spctl -a` reports the bundle as
`rejected` even on the machine that built it. Transfers that set the quarantine flag -- AirDrop, email, a download
-- will be blocked outright, with no right-click bypass on recent macOS. Either
clear the flag on the target machine:

```sh
xattr -dr com.apple.quarantine /Applications/YealinkMonitor.app
```

or copy it by a route that never sets it (`scp`, `rsync`, a Finder copy from a
USB disk). Notarizing with a Developer ID removes this step entirely.

**Think before embedding the secret.** `make-app.sh --embed` will bake the
credentials into the bundle so a copied app just works, and that is a real
decision rather than a convenience. The YMCS AccessKey authorises device
restart, factory reset, firmware push and configuration push across the entire
enterprise. Since YMCS issues one pair per enterprise it cannot be scoped down
or rotated for this app alone, so an embedded bundle is a copyable, unrevokable
grant of that capability -- and a string in a binary comes straight back out
with `strings`. An embedded build is a credential you are handing out, not
merely an app; `provision.sh` exists so you do not have to.

Never commit the secret. This repository is public.

### 5. Tests

```sh
swift test
```

## How it polls

Monitoring starts when the app launches, not when you first open the popover.
That is worth stating because it is easy to get wrong: with
`.menuBarExtraStyle(.window)` SwiftUI builds the popover's content lazily, so
anything hung off it never runs on a Mac that boots and is left alone. The
polling loop is started from the menu bar *label* instead, which is rendered
immediately. Nothing on that path is allowed to block -- notification permission
is requested afterwards, and the keychain is not touched at all unless the
bundle carries embedded credentials.

YMCS does support pushed events -- there is an Event Subscription panel in the
console, under System > Integration > API -- but delivery needs a publicly
reachable URL for YMCS to POST to, which a Mac behind NAT has not got. So this
app polls. The enterprise-wide
budget is 50 requests/second, shared with every other integration using the same
credentials, so the loop stays cheap:

| Every | What | Cost |
|---|---|---|
| `heartbeat` (default 60s) | `GET /v2/dm/statistics/deviceCount?deviceStatus=0` | 1 request |
| when that count moves | `POST /v2/dm/listDevices`, paged at 100 | ~1 request per 100 phones |
| `fullRefresh` (default 600s) | full listing regardless | same |
| `detailRefresh` (default 1800s) | `GET /v2/dm/devices/{id}` for each phone | **1 request per phone** |
| while a device is mid-debounce | full listing, so confirmations can accumulate | same |

A 100-phone fleet at rest costs roughly one request per minute, plus a burst of
one-per-phone every half hour.

That last sweep is the expensive one, and it exists because `listDevices`
returns no LAN IP, no serial and no SIP line state -- only
`GET /v2/dm/devices/{id}` does, one phone at a time. It runs four at a time,
paced by the rate limiter, and the device list is drawn before it starts, so a
slow sweep never delays the window. The **LAN IP** column reads "—" until the
sweep reaches that phone.

### Known limits

- **Detection latency is bounded by YMCS, not by this app.** Phones report in on
  their own schedule; the detail pane shows `lastReportTime` so you can see how
  stale YMCS's own view is.
- **A simultaneous swap hides from the heartbeat.** If one phone drops in the
  same interval as another recovers, the offline count is unchanged. The periodic
  full refresh bounds how long that can go unnoticed.
- **Stale is not offline.** If polling fails, the last known device list stays on
  screen and is clearly marked stale rather than being wiped or presented as
  current.

## Layout

```
Sources/YMCSKit/          API client, polling engine — no UI, fully tested
  Client.swift            typed endpoints, retry and error mapping
  TokenStore.swift        OAuth2 token cache with single-flight refresh
  RateLimiter.swift       GCRA shaper + mandated 30s backoff on 429
  Monitor.swift           heartbeat/full-refresh polling loop, snapshots
  Transitions.swift       debounced online/offline change detection
  AlertDigest.swift       batching and rate limiting for email alerts
  RebootSchedule.swift    calendar-correct scheduled restart times
  Models.swift            devices, alarms, accessories, calls, logs
Sources/SMTPKit/          minimal SMTP submission client — no UI, fully tested
  SMTPClient.swift        EHLO/STARTTLS/AUTH/DATA conversation
  SMTPMessage.swift       RFC 5322 headers and quoted-printable body
  SMTPTransport.swift     CFStream socket, upgradable to TLS in place
Sources/YealinkMonitor/   SwiftUI app
  DemoFleet.swift         the synthetic fleet behind -demoFleet YES
Scripts/smoke-test.sh     Phase 0 API check
Scripts/provision.sh      seed a Mac's keychain and preferences
Scripts/make-app.sh       build the .app bundle without Xcode
Scripts/release.sh        sign, notarize, staple and publish a release
Scripts/make-icon.swift   draws AppIcon.icns from paths at every size
docs/                     the GitHub Pages site
```

## Muting and archiving

Two different things, deliberately kept apart:

- **Mute** — "stop telling me about this phone". It stays in the fleet, stays in
  the counts and still shows its real status; only the notification is withheld.
  Right for a phone with a known fault someone is already dealing with.
- **Archive** — "this phone is not in service". A spare in a cupboard is *meant*
  to be offline, and a monitor showing a permanent red triangle for it trains
  you to ignore red triangles. Archived phones are removed from the menu bar
  count, from the popover, from the status filters and their counts, from alerts
  and email, and from bulk actions — so **Restart All Listed** cannot reach the
  spare in the cupboard.

Archive from the right-click menu in the Phones window or the button in the
detail pane. They are not hidden, just moved: the status filter gains an
**Archived** entry, they are marked in the export's own column, and Settings ▸
Alerts has a **Restore All**.

A schedule that already names a phone you later archive keeps naming it, shown
with an archive marker in the schedule editor. Silently dropping it would change
what a saved schedule does without saying so.

## Exporting

The Phones window has an **Export** menu with the same two scopes as Restart:
everything currently listed (so the filters above are in force -- the menu says
"All Listed" for that reason) or just the selection. The CSV carries what the
window shows plus what the detail sweep has filled in: IP, serial, SIP line
counts, unregistered lines, accessory faults, active alarms and firmware drift.

It is written with a UTF-8 BOM, because Excel otherwise reads the file in the
system's legacy encoding and mangles anything non-ASCII.

## Restarting phones

Restart is the only write this app can perform. Factory reset is not implemented
and is not going to be: `POST /v2/dm/device/reset` differs from the reboot
endpoint by one path segment and takes an identical body, so the protection
against firing it by accident is that no code here can express it.

Three things worth knowing:

- **An offline phone cannot be restarted.** The command goes to YMCS, which has
  no way to reach a phone that is not talking to it. YMCS accepts the request
  regardless, so the app says so rather than reporting success.
- **A restart looks exactly like an outage.** For a settling window afterwards
  (10 minutes by default) the resulting drop is recorded but not alerted. A
  phone that has not come back when the window closes *is* reported.
- **A partial failure is an HTTP 200.** The endpoint answers success and puts
  the detail in `errors[]`, so the app reports counts rather than treating a
  non-error as a job done.

### Scheduled restarts

Settings ▸ Schedules. A schedule is a fixed list of phones, a time, and the days
it runs — saved by device id rather than by site or filter, because a
filter-based schedule silently grows as phones are added.

**Schedules only fire while this app is running and the Mac is awake.** That is
a property of a menu bar app, not something this code can work around: it would
need a LaunchAgent or a server-side scheduler, and YMCS has no scheduling
endpoint. An occurrence missed by less than the grace window runs late and says
so; one missed by longer is recorded as skipped rather than firing at a
surprising time. Every run reports by notification, and by email if configured.

## Diagnostics

Select a phone in the Phones window and use the buttons in its detail pane.
Everything there runs **on the phone**, which is the point: `ping 10.0.0.1` from
this Mac says nothing about whether the handset in the back office can reach its
gateway.

Each one is asynchronous — the request only asks the phone to do something, and
the result arrives later as a file. Ping and traceroute output is shown inline;
logs, config files, screenshots and captures are saved to your Downloads folder
and revealed in Finder. A packet capture runs for its full duration (three
minutes minimum, per the API) before the file exists.

The file type is worked out from the bytes rather than from the documentation,
which is wrong about it: `exportSyslog` is described as producing a text file
and actually returns a zip of `datalog/*.log`. Archives are expanded on arrival,
so **Show in Finder** opens a folder of readable logs rather than a file that
looks corrupt.

## Activity

The **Activity…** window has two things YMCS knows that the device list does not:

- **Call quality** — how calls actually sounded, with the MOS score (1-5) for
  the worse direction. A phone that is online around the clock and rates Bad on
  every call is a fault nothing else here can show.

  Two things the API document gets wrong here, both confirmed against a live
  tenant: `duration` is documented as milliseconds and is actually seconds, so
  durations are derived from the start and end timestamps instead; and
  `callerURI`/`calleeURI` are documented but come back null, so the table shows
  the account and MOS rather than two columns that can never fill.
- **Operation log** — what anyone changed in YMCS, this app included. It answers
  "did someone push config to this phone just before it started dropping?", and
  it is the independent record of restarts this app performed.

Both are fetched when you open the window rather than polled, because neither
feeds an alert and polling them would spend the enterprise's request budget on
data nobody is looking at.

## Email alerts

Settings ▸ Email. Needs an SMTP relay that will accept authenticated submission
— a provider mailbox or an internal relay. STARTTLS on port 587 and implicit TLS
on port 465 are both supported; the password lives in the login keychain next to
the YMCS secret and is never sent over an unencrypted connection.

Alerts are batched (60s by default) so a switch failure that takes forty phones
offline sends one email rather than forty, and capped per hour. Over the cap,
alerts are held and sent together rather than dropped. Quiet hours do **not**
apply to email by default: overnight is usually when you most want to be told.

## Cutting a release

`Scripts/release.sh` builds the universal bundle, signs it with a Developer ID
certificate and the hardened runtime, submits it to Apple's notary service,
staples the ticket into the bundle and packages the result. A notarized bundle
opens on any Mac with none of the quarantine dance above.

```sh
./Scripts/release.sh 0.1.0            # build and notarize
./Scripts/release.sh 0.1.0 --publish  # ... and create the GitHub release
```

It needs two things set up once on the machine that cuts releases:

1. A **Developer ID Application** certificate, from developer.apple.com ▸
   Certificates ▸ + ▸ Developer ID Application. An "Apple Development"
   certificate is a different thing and cannot notarize. On an organisation
   account only the Account Holder can create one.
2. Notary credentials in the keychain:

   ```sh
   xcrun notarytool store-credentials YealinkMonitor \
       --apple-id you@example.com --team-id <team id> \
       --password <app-specific password>
   ```

The script refuses a dirty working tree, and refuses to package a bundle built
with `--embed`: a public release carrying the YMCS AccessKey would hand
enterprise-wide write authority to anyone who clicked Download.

## Not done yet

- App Sandbox. Released builds are signed and notarized with the hardened
  runtime, but not sandboxed.
- Factory reset, configuration push and firmware push — deliberately left out.
  Firmware is read-only here: the table marks a phone running an older build
  than the rest of its model, and stops there.

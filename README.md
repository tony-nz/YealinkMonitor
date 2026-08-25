# YealinkMonitor

A macOS menu bar app that watches Yealink phones through the **YMCS Open API v2**
and tells you when one goes offline.

- Menu bar item showing how many phones need attention, with a popover listing them
- Full window with a sortable, filterable table and a per-device detail pane
- Notifications on confirmed outages and recoveries, with debouncing, quiet hours
  and per-device mutes
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

### 3. Deploying to another Mac

Build the bundle, copy it over, then provision that machine once:

```sh
./Scripts/provision.sh --id '<AccessKey ID>' --region au --app /Applications/YealinkMonitor.app
```

It prompts for the secret (or reads `YMCS_CLIENT_SECRET`), stores it in the
login keychain and writes the Client ID and region to the app's preferences.
`--uninstall` reverses both.

**The secret is deliberately not embedded in the bundle.** The YMCS AccessKey
authorises device restart, factory reset, firmware push and configuration push
across the entire enterprise -- this app only reads, but the credential does not
know that. Since YMCS issues one pair per enterprise, it cannot be scoped down
or rotated for this app alone, so a bundle with the key baked in would be a
copyable, unrevokable grant of that capability. A string in a binary comes
straight back out with `strings`.

For the same reason: never commit the secret. This repository is public.

### 4. Tests

```sh
swift test
```

## How it polls

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
| while a device is mid-debounce | full listing, so confirmations can accumulate | same |

A 100-phone fleet at rest costs roughly one request per minute.

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
Sources/YealinkMonitor/   SwiftUI app
Scripts/smoke-test.sh     Phase 0 API check
Scripts/provision.sh      seed a Mac's keychain and preferences
Scripts/make-app.sh       build the .app bundle without Xcode
Scripts/make-icon.swift   draws AppIcon.icns from paths at every size
```

## Not done yet

- App Sandbox and notarization (needs a Developer ID; ad-hoc signing only for now)
- Anything that writes to devices — reboot, reconfigure, firmware push are all
  deliberately left out

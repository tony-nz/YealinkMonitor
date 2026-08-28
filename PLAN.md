# Plan

## Status

All of it is built and tested. 130 tests pass.

Deliberately still absent, and staying that way: factory reset, configuration
push and firmware push.


Candidate work for YealinkMonitor, grounded in the YMCS Open API v2 doc
("Open API for Yealink Management Cloud Service V4X", document
`c0966bbacb51405397c55290c2925f65`). Section numbers below are the doc's.

## Decisions

- **Reboot, never reset.** `POST /v2/dm/device/reset` (doc 2.3.2) is not
  implemented, not wrapped, and not referenced. The two endpoints differ by one
  path segment and take an identical body, so the protection is that the reset
  path does not exist in this codebase -- not a flag, not a confirmation, not a
  disabled button. Same for `parts/reset` (2.5.4).
- **Reboot is an ordinary action**, guarded by a confirmation naming what it
  will hit. No unlock setting, no re-authentication.
- **Three ways to fire it**: one phone from the detail pane, a selection or
  filtered set in bulk, and on a schedule for a chosen set of phones.
- **Email alerts over SMTP**, configured in Settings, password in the Keychain
  next to the client secret.

One documentation fix fell out of this, and is done: the README claimed the
secret is "deliberately not embedded in the bundle", which `--embed`
([make-app.sh:114](Scripts/make-app.sh#L114)) had made untrue. It now describes
the choice and its cost. That matters more now reboot has shipped, because an
embedded bundle hands over a working fleet-restart button along with the
credential.

## 1. Reboot (doc 2.3.1) — done

```
POST /v2/dm/device/reboot
{ "deviceIds": ["<id>", ...],   // String[], required, max 200
  "deviceType": 1 }             // required -- 1 = Phone, 3 = Room
```

Batch semantics: a partial failure is still `200`, with the detail in the body.

```json
{ "total": 2, "successCount": 1, "failureCount": 1,
  "errors": [{ "field": "<deviceId>", "msg": "The resource does not exist or has been deleted" }] }
```

(The doc's response table for this endpoint is copy-pasted from factory reset
and mislabels the fields as "factory restored devices". The field names are
right; the prose is not.)

**Client.** `YMCSClient.rebootDevices(ids:deviceType:) -> RebootResult` in
[Client.swift](Sources/YMCSKit/Client.swift), chunked at 100 to match the
existing paging idiom rather than the documented 200. `RebootResult` carries
`total`, `successCount`, `failureCount` and the decoded `errors[]`, merged
across chunks. Reporting "rebooted 12 phones" when four failed is the failure
mode to design against, so `successCount != total` must reach the caller and
the UI, not just a log line.

**Reach.** Three entry points, one code path:

- Detail pane: reboot this phone.
- Devices window: reboot the current multi-selection.
- Filtered bulk: reboot everything currently listed -- which, given the window
  already filters, covers "all offline" and "everything at this site" without
  new query work. The confirmation states the count and the filter in words
  ("Reboot 23 phones matching: site = Wellington, status = offline"), because
  a bulk action off a filter the user has forgotten is the way this goes wrong.

**Offline phones can't receive it.** The command goes to YMCS, not to the
phone. Rebooting an offline device is accepted and simply never happens. Say so
in the result rather than reporting success.

**A reboot looks exactly like an outage.** After firing, the phone drops and
returns, and [Transitions.swift](Sources/YMCSKit/Transitions.swift) will confirm
it as a regression and notify -- including by email, at 2am, for a scheduled
run. So the reboot path registers a suppression: for each device ID, ignore
regressions for a window (default 10 minutes, settable) and mark the
[HistoryStore](Sources/YealinkMonitor/HistoryStore.swift) entry as
operator-initiated so the history reads "rebooted" rather than "went offline".
If a phone does not come back inside the window, that *is* worth an alert --
suppression expires and the normal path takes over.

Accessory restart (doc 2.5.3, `POST /v2/dm/devices/{deviceId}/parts/reboot`,
optional `partIds`, omit for all accessories on the device) is the same shape
and follows once accessories are visible at all -- see section 5.

## 2. Scheduled reboots — done

A named schedule: a set of phones, a time, a repeat rule (daily, or chosen
weekdays), on or off.

**The hard constraint:** this is a menu bar app, not a daemon. A schedule fires
only while the app is running and the Mac is awake. A closed laptop at 3am
reboots nothing. That is not fixable inside the current architecture -- it would
need a LaunchAgent, or moving the trigger server-side, and YMCS has no
scheduling endpoint. So the design has to be honest about it:

- Persist `lastFired` per schedule. On launch and on wake, if the occurrence was
  missed and the scheduled time is within a grace window (default 60 minutes),
  fire it late and say it was late. Outside the window, skip it and record the
  skip.
- Never silently fire a three-day-old missed occurrence. A stale reboot landing
  mid-morning is worse than a skipped one.
- Show each schedule's next fire time *and* last outcome in Settings, so a
  schedule that has been quietly skipping for a week is visible.
- Consider `NSBackgroundActivityScheduler` over a plain timer so macOS can wake
  the machine for it where power settings allow; document that this is
  best-effort. Compute the next date with
  `Calendar.nextDate(after:matching:)` rather than adding 86400, so DST does not
  drift the schedule by an hour.

**Selection.** v1 stores an explicit list of device IDs, displaying current
names. A site- or filter-based schedule silently grows as phones are added,
which is a fleet-wide reboot nobody authored. If a stored ID no longer resolves,
show it as missing rather than dropping it quietly.

**No human is present when it fires**, so the guard moves to authoring time:
the confirmation happens when the schedule is saved, listing the phones by name,
and every run reports afterwards -- notification and, if configured, email, with
the same partial-failure detail as a manual run. Reuse the section 1 suppression
so a scheduled run does not generate an outage storm.

## 3. Email alerts over SMTP — done

Settings gains an Alerts section: recipient(s), SMTP host, port, STARTTLS/implicit
TLS, username, password (Keychain, same treatment as the client secret in
[Keychain.swift](Sources/YealinkMonitor/Keychain.swift)), and a **Send test
email** button that reports the real SMTP error on failure.

**There is no SMTP client in Foundation**, and the package currently has zero
dependencies ([Package.swift](Package.swift)). Recommendation: hand-roll it over
`Network.framework` in a new `SMTPKit` target rather than pulling in SwiftNIO for
one feature. It is a contained amount of work -- EHLO, STARTTLS upgrade, AUTH
PLAIN/LOGIN, MAIL FROM/RCPT TO/DATA -- provided the details are respected: CRLF
line endings, dot-stuffing the body, and correct `Date`, `Message-ID`, `From`,
`To` and `Subject` headers, without which the mail is spam-foldered. A new
target also means it gets a fake-server test suite in the style of
[FakeServer.swift](Tests/YMCSKitTests/FakeServer.swift), which the same code
buried in the app target would not.

**What gets sent.** Email hangs off the same confirmed `StatusChange` stream as
[Notifier.swift](Sources/YealinkMonitor/Notifier.swift) and honours the existing
per-device mutes. Two differences from local notifications:

- **Coalesce.** A switch failure takes forty phones offline at once. Forty
  emails is an unusable inbox and a good way to get the sending account rate-
  limited. Buffer changes for a window (default 60s) and send one email:
  "12 phones offline at Wellington". Cap sends per hour and note in the email
  when a cap was hit.
- **Quiet hours should not apply by default.** Quiet hours exist to avoid
  interrupting the person at the Mac; email is the channel you actually want
  overnight. Make it a separate toggle, defaulting to send.

**Failures must be loud.** A monitor whose alerting silently stopped is worse
than no monitor. Retry with backoff, and surface the last send error in the
menu bar popover the same way a stale poll is surfaced.

## 4. Alarms in the UI (doc 12.1) — done

`listAlarms` is already written and tested ([Client.swift:137](Sources/YMCSKit/Client.swift#L137))
and nothing in the UI calls it. Cheapest real feature here: an alarm count in
the popover, a per-device alarm list in the detail pane. Alarms carry `level`,
`firstAlarmTime`/`lastAlarmTime` and `status`, so they answer "was this phone
already unhealthy before it dropped?", which the current online/offline view
cannot.

## 5. Accessories (doc 2.5.1, 2.5.2, 2.5.5) — done

Per-device listing of headsets, expansion modules and the like. Read-only, and a
real gap -- a phone reporting healthy with a dead expansion module currently
looks fine. Batch query (2.5.5) keeps it affordable fleet-wide. Unlocks
accessory restart from section 1.

## 6. Diagnostics (doc 11.x) — done

All per-device, all sharing one pattern: start a job, get a `diagnosisId`, poll
`GET /v2/dm/diagnosis/{id}/status` until `success`, then download the signed
`url`.

- `PUT /v2/dm/devices/{id}/captureScreen` -- screenshot (11.4)
- `PUT /v2/dm/devices/{id}/exportSyslog` -- system log (11.5)
- `PUT /v2/dm/devices/{id}/exportConfig` -- config file (11.6)
- `PUT /v2/dm/devices/{id}/ping` -- `{host, times}`, 1-30 (11.7)
- `PUT /v2/dm/devices/{id}/traceroute` (11.8)
- `GET /v2/dm/devices/{id}/networkInterfaces` -- feeds packet capture (11.1-11.3)

Build the poll loop once as a generic `DiagnosticJob`, then layer six thin verbs
on it. "Ping the gateway from the phone that keeps dropping" is what turns this
from an observer into a diagnostic tool.

## 7. Call quality (doc 6.1, 6.2, 7.2) — done

`POST /v2/dm/listQoes` (filter by mac, siteIds, time range, limit 500) and
`POST /v2/dm/statistics/qoe` (`total`, `badTotal`, `badPercentage`,
`goodPercentage`). Turns "is it up?" into "is it usable?" -- a phone that is
always online but always bad never trips today's alerting at all.

## 8. Sites as a first-class filter (doc 9.x) — done

`listSites` is already fetched ([Client.swift:165](Sources/YMCSKit/Client.swift#L165))
and used only for naming. Site-scoped filtering, site-scoped mutes and per-site
offline counts are cheap given the data is already in hand -- and site filtering
is what makes bulk reboot in section 1 useful.

## 9. Operation log (doc 13.1) — done

`POST /v2/dm/listOpLogs` -- module, operationType, operationObject, operator,
time-filtered. Answers "did someone push config to this phone right before it
started dropping?", the most common cause the app currently cannot see. Also the
independent audit trail for our own reboots.

## 10. Firmware (doc 10.1) — done, read-only

Firmware list, official firmware list, and `Device.programVersion` already in
hand: flag phones behind the fleet's modal version. Push (10.1.4, 10.1.5) is a
write action with a far worse failure mode than reboot and is not planned.

## Order of work

Everything above is in scope. Sequencing is about what unblocks what, not about
scope:

1. ~~**Sites (8)** and **alarms (4)**~~ -- done. Site filtering already existed
   and now names itself in the bulk-restart confirmation; alarms are in the
   popover, the table and the detail pane.
2. ~~**Reboot (1)**~~ -- done. Single, selection and filtered bulk, with the
   settling window and partial-failure reporting.
3. ~~**Email (3)**~~ -- done. `SMTPKit` plus `AlertDigest`.
4. ~~**Scheduled reboots (2)**~~ -- done.
5. ~~**Accessories (5)**, then **accessory restart**~~ -- done.
6. ~~**Diagnostics (6)**, **QOE (7)**, **op log (9)**, **firmware read-only
   (10)**~~ -- done. Diagnostics share one ticket-and-poll helper; call quality
   and the operation log live in a new Activity window and are fetched on
   demand rather than polled.

## Assumptions worth correcting

- **Scheduled restarts are best-effort while the Mac is awake and the app is
  running.** This is now built and behaves as described -- late runs inside the
  grace window, skips recorded outside it -- but if they need to fire reliably
  overnight, that is a different architecture (a LaunchAgent, or a small
  always-on host) and the work above does not deliver it.
- Email batching window (60s), the hourly cap (12) and the 10-minute settling
  window are guesses. All three are settings, with those as defaults.
- SMTP relay availability is assumed. If there is no relay that will accept
  authenticated submission from these Macs, section 3 does not work as
  described and a webhook is the fallback.
- Device type is recovered from the model lookup, because `listDevices` does not
  return one and the reboot endpoint requires it. An unrecognised model falls
  back to phone.
- Firmware drift compares against the *commonest* build for a model, not the
  highest, so one phone on a beta does not mark the fleet out of date. It is
  informational: this app does not push firmware.
- Diagnostic downloads are written to ~/Downloads. An App Sandbox build would
  need a user-selected save location instead.

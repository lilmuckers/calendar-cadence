# Cadence

<img src="Support/AppIcon.png" width="128" alt="Cadence icon: a panicking calendar page with googly eyes">

Minimal macOS menu-bar calendar monitor.

- **Menu bar** — next meeting countdown; click for today's agenda with calendar colours, metadata, Join buttons, and expandable map + travel time for in-person meetings.
- **Floating countdown panel** — glass pill, always on top, all Spaces. Drag anywhere; snaps to screen edges.
- **Full-screen takeover** — 30 s before a meeting (configurable), on every display. Return joins, Esc dismisses, Snooze re-alerts after 1 min.
- **Sources** — every account in macOS Calendar (iCloud, Google, Exchange/Outlook, CalDAV, subscriptions). Add accounts in System Settings → Internet Accounts.
- **Filters** — per-calendar toggles, hide all-day/declined/tentative/free/no-link, title keyword include/exclude, minimum duration.
- **Join link detection** — URL field, location, and invite body (HTML included). Zoom, Google Meet, Teams, Webex, GoTo, Whereby, Jitsi, Chime, Slack, BlueJeans, Skype, Discord, FaceTime, Around, Tuple, RingCentral. Unwraps Outlook SafeLinks, Google and Proofpoint redirects. Zoom/Teams open in their native apps when installed.

## Build

Needs only Xcode Command Line Tools (macOS 14+). No SwiftPM, no Xcode project.

```bash
scripts/test.sh            # unit tests (Swift Testing)
scripts/build.sh --run     # build build/Cadence.app and launch it
CONFIG=debug scripts/build.sh
scripts/icon.sh            # regenerate Support/AppIcon.icns from scripts/make-icon.swift
```

The default ad-hoc signature changes every build, so macOS may ask for calendar access again after rebuilding. To avoid that, sign with a stable identity:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" scripts/build.sh
```

For launch-at-login, copy `build/Cadence.app` to `/Applications` first.

## Layout

- `Sources/CadenceCore` — pure logic (models, filters, link detection, alert planning). Unit-tested.
- `Sources/Cadence` — the app: EventKit provider, AppState, SwiftUI/AppKit UI.
- `Tests/CadenceCoreTests` — tests.

New calendar sources (direct Google API, ICS feeds) plug in by conforming to `CalendarProvider` and adding to `AppState.providers`.

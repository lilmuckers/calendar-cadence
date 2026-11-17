<div align="center">

<img src="Support/AppIcon.png" width="160" alt="Cadence app icon: a panicking calendar page with googly eyes shouting LATE!">

# Cadence

**Your calendar, gently panicking on your behalf.**

A tiny, native macOS menu-bar app that watches every calendar you have, counts down to your next meeting,<br>
finds the join link wherever it's hiding, and — 30 seconds before you're due — takes over the whole screen so you're never late again.

<p>
<img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000000?style=flat-square&logo=apple&logoColor=white">
<img alt="Swift" src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white">
<img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF?style=flat-square">
<img alt="Dependencies" src="https://img.shields.io/badge/dependencies-0-34C759?style=flat-square">
<img alt="Tests" src="https://img.shields.io/badge/tests-54%20passing-34C759?style=flat-square">
</p>

<img src="docs/screenshots/menubar.png" width="560" alt="Menu bar showing Cadence: 8m · Design Review">

</div>

<br>

<table>
<tr>
<td width="50%" valign="top">
<img src="docs/screenshots/menu.jpg" alt="Today's agenda dropdown with colour-coded meetings and Join buttons">
</td>
<td width="50%" valign="top">

### 📅 Today, at a glance
Click the menu bar for a colour-coded agenda: times, calendar, meeting service or location, attendee count, a live **NOW** badge with progress, and a one-click **Join** on everything joinable. Past meetings fade; clashes get a ⚠️.

Expand an in-person meeting for a **map**, **live travel time** and a "leave in 12m" hint.

### ⏱️ A countdown that floats
<img src="docs/screenshots/panel.jpg" width="100%" alt="Floating countdown panel: Up next, Design Review in 7:19">

A glass pill that sits above everything, on every Space. Drag it anywhere — it snaps to edges.

</td>
</tr>
</table>

## 🚨 The full-screen nudge

<img src="docs/screenshots/takeover.jpg" alt="Full-screen alert: Starting in 0:23, Design Review, Join Google Meet">

30 seconds before a meeting (configurable), Cadence covers every display with a countdown and a big **Join** button.
<kbd>Return</kbd> joins · <kbd>Esc</kbd> dismisses · **Snooze** nags you again a minute later.

### …but not while you're presenting

Cadence checks what you're doing before it shouts:

| You are… | What happens (default) |
|---|---|
| Just working | Full-screen alert on all displays |
| Presenting a Keynote/PowerPoint slideshow, or sharing your screen in Zoom/Teams | Displays being shown are **never** covered — a small banner appears on another display instead |
| On a call (an app is using your microphone) | Small banner, no focus stealing |
| Presenting on every display | Falls back to a macOS notification (which macOS hides from your audience) |

<img src="docs/screenshots/banner.jpg" width="460" alt="Compact banner: Design Review, starts in 0:23, Join">

Each situation is configurable (full-screen / banner / notification / nothing), and **Settings → Alerts** shows a live "Right now: …" readout so you can check detection mid-presentation.

## ⚔️ Double-booked? It asks.

<img align="right" src="docs/screenshots/clash.jpg" width="340" alt="Double-booked! Which one should I alert you for?">

The moment Cadence spots two meetings that overlap — real clashes, not the same invite copied onto two calendars — a card slides in at the top right asking which one you want alerts for. Your choice sticks; the other is quietly muted (🔕 in the agenda).

<br clear="right">

## ✨ Everything else

- **🔗 Join links from anywhere.** URL field, location, or buried in an HTML invite body. Zoom, Google Meet, Microsoft Teams, Webex, GoTo, Whereby, Jitsi, Chime, Slack huddles, BlueJeans, Skype, Discord, FaceTime, Around, Tuple and RingCentral. Outlook SafeLinks, Google and Proofpoint redirect wrappers are unwrapped, and Zoom/Teams open straight in their apps.
- **⌨️ Global join shortcut.** <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>J</kbd> (re-bindable) joins whatever's starting in the next 10 minutes — or the meeting you're already late for.
- **🚗 "Leave now" reminders.** For in-person meetings, Cadence watches live traffic and pings you at configurable offsets before you need to leave (default: 10 minutes before, and "time to leave").
- **🔔 Heads-up notifications.** Optional nudge N minutes before each meeting (default 5).
- **🧹 Filters.** Toggle calendars; hide all-day, declined, tentative, free or link-less events; include/exclude by title keyword; minimum duration.
- **😰 A menu bar icon with feelings.** Calm, nervous at 15 minutes, sweating at 5.

<p align="center"><img src="docs/screenshots/moods.png" width="360" alt="Menu bar icon moods: calm, nervous, panicking"></p>

## 🗂️ Calendar sources

| Source | How |
|---|---|
| **macOS Calendar** | Everything you've added in *System Settings → Internet Accounts*: iCloud, Google, Exchange/Outlook, CalDAV, subscriptions. Just grant access. |
| **ICS / webcal feeds** | *Settings → Accounts → Subscribed calendars.* Paste any iCalendar link — Google's "secret address in iCal format", Outlook's published ICS, team rotas, sports, holidays. Recurrence, exceptions and Windows time zones are handled. |
| **Google Calendar (direct)** | *Settings → Accounts → Google → Sign in with Google.* Optional, and you can add **multiple accounts** (work, personal…); gives Meet links and RSVPs straight from Google. Builds with a built-in OAuth client need nothing else; otherwise bring your own (see below). |

The same meeting arriving from several sources is merged automatically.

<details>
<summary><b>Setting up the Google OAuth client</b></summary>

If the build you're using has a Google client built in, skip this: just click **Sign in with Google**. These steps are for building Cadence yourself, or for using your own client (*Settings → Accounts → Use my own OAuth client…*).

About five minutes in [Google Cloud Console](https://console.cloud.google.com/):

1. **Create a project** (project picker → *New project*, e.g. `Cadence`) and select it.
2. **Enable the API:** *APIs & Services → Library →* **Google Calendar API** *→ Enable*.
3. **Consent screen:** *Google Auth Platform → Get started* (older consoles: *APIs & Services → OAuth consent screen*). App name `Cadence`, your email as support contact, then pick an **Audience**:
   - **Internal**: Google Workspace accounts only, signing in within your own domain. Simplest option: no test users, and sign-ins don't expire.
   - **External**: personal `@gmail.com` accounts, or more than one domain. See the note below.
4. *(Optional)* **Data Access → Add or remove scopes →** `.../auth/calendar.readonly`. Cadence requests this scope anyway; adding it here makes the consent screen accurate.
5. **Create the client:** *Clients → Create client →* Application type **Desktop app**. Copy the **Client ID** and **Client secret**. You don't need a redirect URI: Desktop clients accept Cadence's `http://127.0.0.1:<port>` loopback automatically.
6. Either **build it in** for everyone who uses your build (next section), or paste both values into **Cadence → Settings → Accounts → Use my own OAuth client…**. Then click **Sign in with Google**, choose your account and **Allow**. The browser tab says *"Cadence is connected"* when it's done.

> [!IMPORTANT]
> **External apps start in "Testing" mode, and Google expires their refresh tokens after 7 days.** Cadence then shows *Not signed in* and you have to sign in again. You also have to add every account you'll use under *Audience → Test users*, or sign-in fails with *"Access blocked"*.
>
> To stop the weekly re-sign-in, click **Publish app** under *Audience* so its status becomes *In production*. You don't need Google's verification for personal use. Sign-in then shows *"Google hasn't verified this app"*: choose **Advanced → Go to Cadence (unsafe)**. That's expected, because the OAuth client is your own.

Cadence uses the loopback redirect + PKCE flow and asks only for `calendar.readonly`. It keeps the client secret and refresh token in your Keychain; after an ad-hoc-signed rebuild, macOS may ask to allow Keychain access, so choose **Always Allow**. Add as many Google accounts as you like with **Add Another Account**; Google shows its account chooser each time. If one stops working (for example, after the 7-day Testing-mode expiry), it's marked **Reconnect** rather than removed. Meetings that appear in several accounts, or in macOS Calendar too, are merged automatically.
</details>

## 🛠️ Build & run

No Xcode project, no SwiftPM, no dependencies — just the Xcode Command Line Tools on macOS 14+.

```bash
scripts/test.sh            # 54 unit tests (Swift Testing)
scripts/build.sh --run     # build build/Cadence.app and launch it
```

### Building in a Google OAuth client

Save the client as `Support/Secrets.env` (git-ignored; `Support/Secrets.env.example` shows the format), or export the same two variables:

```bash
GOOGLE_CLIENT_ID=1234-abc.apps.googleusercontent.com
GOOGLE_CLIENT_SECRET=GOCSPX-…
```

`scripts/build.sh` writes them into the app's `Info.plist`, so users only see **Sign in with Google**. A client someone enters in Settings still takes priority.

> [!NOTE]
> Google treats Desktop-app client secrets as non-confidential: PKCE protects the sign-in itself, and anyone with the `.app` can read the secret. Keep it out of git anyway, so nobody else's builds use your project's quota.
> To let people outside your test-user list sign in, **publish** the consent screen. Unverified apps are capped at 100 users and show a warning. Above that, Google requires verification for the `calendar.readonly` scope: a privacy policy, a homepage, and a demo video.

### More build options

```bash
CONFIG=debug scripts/build.sh                                     # debug build
CODESIGN_IDENTITY="Apple Development: you@example.com" scripts/build.sh   # stable signature
scripts/icon.sh                                                   # regenerate the app icon
build/Cadence.app/Contents/MacOS/Cadence --screenshots docs/screenshots   # regenerate these images
```

> [!TIP]
> Builds are ad-hoc signed by default, so macOS may re-ask for calendar (and Keychain) access after each rebuild. Set `CODESIGN_IDENTITY` to a real signing identity to avoid that, and copy the app to `/Applications` to use **Launch at login**.

## 🔒 Privacy

Everything runs locally. Cadence talks only to the services you connect (Google's API, your ICS feed hosts) and Apple Maps for travel times. Presentation and call detection read window positions and microphone *usage* — never screen contents or audio — and need no Screen Recording or Microphone permission.

## 🧬 How it's built

```
Sources/
├── CadenceCore/          Pure, tested logic — no UI frameworks
│   ├── MeetingLinkDetector   find & unwrap join links
│   ├── ICS                   iCalendar parser + RRULE expansion
│   ├── GoogleCalendarModels  Google API → Meeting
│   ├── Deduplication         merge copies across sources
│   ├── FilterSettings        user filters
│   ├── AlertPlanner          when the takeover fires (snooze, late wake)
│   ├── AlertPolicy           presenting/call detection → how to alert
│   └── Reminders             heads-up, leave-now, clash detection
└── Cadence/              The app
    ├── Sources/              EventKit, ICS and Google providers, OAuth, Keychain
    ├── Engine/               system context, alert routing, travel, hotkey, notifications
    └── UI/                   menu, panel, takeover, banner, clash prompt, settings
```

New sources plug in by conforming to `CalendarProvider`.

<div align="center">
<br>
<sub>Made for people who are definitely, absolutely, five minutes away.</sub>
</div>

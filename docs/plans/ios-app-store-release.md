# Plan: the iPhone app on the App Store

The Mac app stays outside the store: a notarized DMG from `release.yml`, with every feature. The
Mac App Store needs the App Sandbox, which would cost core features (assistant set-up, browser
profiles, media keys, the MCP socket). Only the iPhone app goes in the store.

## Done in code
- [x] Privacy manifests: `iOS/Cadence/PrivacyInfo.xcprivacy` and `iOS/Widgets/PrivacyInfo.xcprivacy`.
  No tracking, nothing collected. UserDefaults reasons: `CA92.1` (the app's own settings) and
  `1C8F.1` (the App Group the widgets read). If new code uses another required-reason API (file
  timestamps, system boot time, disk space, active keyboards), add it here.
- [x] `ITSAppUsesNonExemptEncryption = NO` in `iOS/Config/Cadence-Info.plist`: only the OS's own
  encryption (HTTPS, and TLS-PSK to the Mac), which is exempt.
- [x] iPhone only: `TARGETED_DEVICE_FAMILY = 1`, iPad orientations removed.
- [x] Spotify reads as an optional extra: Settings → Music & Media → Spotify → **Track details: Off**
  until a Client ID is added. Opening Spotify and pausing it for meetings work without one.

- [x] **Volume pill.** The Mac's volume keys still move the phone's volume through the slider in an
  `MPVolumeView` (not a supported API), but that view is now visible while it does: a small glass
  pill on the desk (above the media card in landscape, bottom centre otherwise) for ~1.6 s after
  each key, and it can be dragged while it's up. `-previewVolume` keeps it up for layout checks.
  The Simulator has no volume route, so the slider itself only shows on a real phone.
- [ ] Check the pill on a real phone (slider tint and thumb, and that iOS's own volume overlay
  stays away).
- [ ] If App Review still objects: drop volume from the Mac's keys (play/pause/skip stay) and
  leave the pill as a plain volume control.
- [x] **Demo calendar for App Review**: `docs/demo/review-calendar.ics`, a 30-minute meeting every
  hour of every day in the viewer's own time zone. 23 have a working Jitsi link (Join opens a real,
  empty room); the 12:00 lunch is in person, with a map. Tested in `SourceTests` (`reviewDemoFeed`).
  Once merged it's at
  `https://raw.githubusercontent.com/lilmuckers/calendar-cadence/main/docs/demo/review-calendar.ics`
  (or copy it to `cadence.patrick-mckinley.com/demo.ics` for a tidier link).
- [x] **First launch**: a three-page welcome (what it does, where meetings come from, alerts and desk
  mode), **Try with sample meetings** (made up on the phone, a meeting every hour plus one two
  minutes after turning it on, to show the alert), a designed empty home screen, a desk-mode tile,
  one-off tips, and a launch screen in the home screen's colour. Notifications are asked for on the
  welcome's last page, or when the first calendar or Mac is connected, never at launch.
- [x] Local Network denied: the Mac row says so, with **Open Settings**, instead of a raw error.
- [x] Apple Music access is asked for when you tap through to Music on the desk or pick Apple Music
  in Settings, not on launch. (On recent iOS even *reading* the permission status shows the prompt,
  so the app doesn't read it until it has asked once.) Installs from before this change see the
  prompt once more, the first time they tap through to Music.
- [x] Branded **Sign in with Google** / **Sign in with Microsoft** buttons (`SignInButtons.swift`):
  Google's standard "G" and light/dark colours, Microsoft's four squares, exact wording.
- [x] `-previewVolume` only works in Debug builds, like the other `-preview…` arguments.
- [x] **TestFlight from GitHub Actions**: the Release workflow's `ios` job archives, signs and uploads
  the iPhone app. It switches on once its secrets exist (see "6. GitHub Actions" below); dry runs
  keep the `.ipa` as an artifact instead of uploading.

## You: once the developer account is active

### 1. Apple identifiers
- [ ] Find your **Team ID**: developer.apple.com → Account → Membership details.
- [ ] Choose a bundle ID you own, e.g. `com.<you>.cadence` (the widget becomes `<id>.widgets`, the
  App Group `group.<id>`).
- [ ] Put both in `iOS/Config/Local.xcconfig`:
  ```
  DEVELOPMENT_TEAM = <Team ID>
  CADENCE_BUNDLE_ID = com.<you>.cadence
  ```
- [ ] Open the project in Xcode, select the **Cadence** and **CadenceWidgets** targets → Signing &
  Capabilities. With automatic signing Xcode registers both App IDs and the App Group itself.
  Check at developer.apple.com → Identifiers that:
  - `<id>` has **App Groups** (`group.<id>`) and **Time Sensitive Notifications**.
  - `<id>.widgets` has **App Groups** (`group.<id>`).
- [ ] Optional: ask Apple for the **User-Assigned Device Name** entitlement for `<id>` (a form
  linked from that capability's page), then use `Config/Cadence-DeviceName.entitlements`.
- [ ] App Store Connect → Apps → **+ New App** with that bundle ID, to reserve the name early.

### 2. Google: one Cloud project for both apps
The Mac and iPhone share the Mac's existing Cloud project, with a Desktop client and an iOS client.
Every scope is *sensitive* (the built-in client doesn't ask for the *restricted* `gmail.send`), so one
standard verification covers both apps. If Google holds up the Chat scopes, the iPhone waits too.
- [x] **Clients → Create client → iOS**, with the bundle ID. `GOOGLE_IOS_CLIENT_PREFIX` is set in
  `Local.xcconfig` and as a GitHub repository variable for `release.yml`.
- [ ] **APIs**: Google Calendar API and Google Chat API on, Gmail API off. Chat API → Configuration:
  name, icon and description filled in.
- [ ] **Data access**: `openid`, `email`, `profile`, `.../auth/calendar.calendarlist.readonly`,
  `.../auth/calendar.events`, `.../auth/chat.spaces.readonly`, `.../auth/chat.spaces.create`,
  `.../auth/chat.messages.create`. Nothing else, and no `gmail.send`. One line of justification each.
- [ ] Google Search Console: verify `patrick-mckinley.com` with the account that owns the project.
- [ ] **Branding**: app name, support email, logo, home page and privacy policy on
  `cadence.patrick-mckinley.com`, authorised domain `patrick-mckinley.com`.
- [ ] Privacy policy: what's read (calendar events, Chat spaces) and why, kept on your devices and never
  sold or shared, how to delete it, and Google's Limited Use statement word for word.
- [ ] **Audience**: External; add yourself and any TestFlight testers as test users until it's published.
- [ ] Demo video (unlisted YouTube): sign-in with the client ID visible in the URL, meetings appearing,
  replying to an invite and setting a colour, and a running-late Google Chat message (needs a Workspace
  account). The iPhone sign-in too, ideally.
- [ ] Audience → **Publish app**, then Verification Center → **Submit for verification**. Start early:
  until it's verified, sign-in shows an "unverified app" warning and stops at 100 users.

### 3. Microsoft
- [ ] entra.microsoft.com → App registrations → the Mac's registration (or a new one, with
  *Accounts in any organizational directory and personal Microsoft accounts*).
- [ ] Authentication → **Add a platform → iOS / macOS** → the bundle ID. That adds the redirect
  `msauth.<id>://auth`.
- [ ] API permissions (delegated): `User.Read`, `Calendars.ReadWrite`, `MailboxSettings.Read`,
  `offline_access`, `openid`, `email`, `profile`.
- [ ] Put the **Application (client) ID** in `Local.xcconfig` as `MICROSOFT_CLIENT_ID`.
- [ ] **Publisher verification** (Branding & properties): set the publisher domain to
  `patrick-mckinley.com`, verify it, and link a Microsoft AI Cloud Partner Program ID (free to
  join). Without it, many work and school tenants block users from consenting. Personal Microsoft
  accounts aren't affected.

### 4. Review notes and video
- [ ] Tell the reviewer about **Try with sample meetings** (on the welcome's second page, the empty
  home screen, and Settings → Calendars): the quickest way to see everything, no account needed.
  An alert comes up two minutes after turning it on.
- [ ] Also add the demo feed to the review notes: "Settings → Calendars → Subscribed calendars, paste
  `<demo feed URL>`, Add". There's a meeting every hour, so the countdown, Join, the full-screen
  alert, the Live Activity and the widgets can all be tried within the hour.
- [ ] A 30–60 second screen recording: pairing with the Mac (show the code on the Mac, scan it),
  the desk display, Join opening on the Mac.
- [ ] Review notes to paste into App Store Connect:
  - The app works fully without a Mac: add an ICS feed, a Google or Microsoft account, or use the
    phone's own calendars.
  - The Mac app is a free companion download from `cadence.patrick-mckinley.com`; the video shows
    pairing.
  - Spotify track details are optional and need the user's own Spotify developer app; Spotify can
    still be opened and paused without one.
  - A test Google account with a few meetings in its calendar, if Google sign-in is to be tried.

### 5. App Store Connect listing
- [ ] **EU trader status (Digital Services Act): non-trader.** Free app, no monetisation, so declare
  yourself a non-trader in App Store Connect → Business before submitting; your address and phone
  then aren't shown on the store page.
- [ ] **Pricing: Free**, all countries. No Paid Apps agreement, banking or tax forms needed.
- [ ] **Age rating**: fill in the questionnaire (no objectionable content, no user-generated
  content, no web browsing inside the app); it should come out at the lowest rating.
- [ ] Privacy policy URL (`cadence.patrick-mckinley.com/privacy`): what's read (calendars, camera
  for the pairing code, local network, Apple Music), that it goes straight to Google / Microsoft /
  your own Mac, and that there's no tracking or analytics.
- [ ] App Privacy labels: "Data not collected", matching the privacy manifest.
- [ ] Name and subtitle (have a couple of backups in case "Cadence" is taken).
- [ ] Screenshots at 6.9": desk display portrait and landscape, the full-screen alert, the Live
  Activity, widgets, pairing.
- [ ] Age rating, category (Productivity), support URL.

### 6. GitHub Actions (TestFlight uploads)
The Release workflow's `ios` job does the archive and upload; it never submits for review. Add these
under the repo's Settings → Secrets and variables → Actions:
- [ ] **Distribution certificate**: Xcode → Settings → Accounts → Manage Certificates → **+ Apple
  Distribution**. Then in Keychain Access, export it (with its private key) as a `.p12` with a
  password. Secrets: `IOS_DISTRIBUTION_P12` = `base64 -i cert.p12 | pbcopy`,
  `IOS_DISTRIBUTION_P12_PASSWORD`.
- [ ] **Provisioning profiles**: developer.apple.com → Profiles → **+** → *App Store Connect* → the
  app's ID → that certificate. Again for `<id>.widgets`. Download both and save as secrets
  `IOS_APP_PROFILE` and `IOS_WIDGET_PROFILE` (`base64 -i file.mobileprovision | pbcopy`).
  Profiles expire with the certificate (a year): renew both and update the secrets.
- [ ] **App Store Connect API key**: App Store Connect → Users and Access → Integrations → Team
  Keys → **+**, role *App Manager*. Secrets: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the
  whole `.p8` file; it can only be downloaded once).
- [ ] `APPLE_TEAM_ID` and `MICROSOFT_CLIENT_ID` secrets (shared with the Mac build).
- [ ] Variables: `IOS_BUNDLE_ID`, `GOOGLE_IOS_CLIENT_PREFIX` (and optionally `SPOTIFY_CLIENT_ID`).
- [ ] Try it: run **Release** with *dry_run* on; it builds a signed `.ipa` as an artifact without
  uploading. Then a real release uploads to TestFlight.
- The marketing version is the release version (`v1.2.0` → 1.2.0); the build number is the run
  number followed by the attempt. CI builds with Xcode 26.6 (iOS 26 SDK, which App Store Connect
  requires today); move `XCODE_VERSION` to 27 when GitHub has a stable macOS 27 runner, before Apple
  starts requiring the iOS 27 SDK (usually each April).

### 7. Before submitting
- [ ] Publish the notarized Mac DMG, so the links in the app and review notes work.
- [ ] Run the **Release** workflow to upload to TestFlight. Test on your own phone, then external
  TestFlight (its beta review is a cheap dry run for App Review).
- [ ] In App Store Connect, pick that build for the version and **Submit for Review**.
- [ ] Submit once Google verification has passed.

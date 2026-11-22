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

### 2. Google: a separate Cloud project for iOS
The Mac's project asks for `gmail.send` (a *restricted* scope, which needs a yearly paid security
assessment). The iPhone only needs calendar access (*sensitive*: standard verification only), so
it gets its own project.
- [ ] console.cloud.google.com → **New project**, e.g. "Cadence iPhone".
- [ ] APIs & Services → Library → enable **Google Calendar API**.
- [ ] Google Auth Platform → **Branding**: app name, support email, logo, home page and privacy
  policy on `cadence.patrick-mckinley.com`, authorised domain `patrick-mckinley.com` (verify the
  domain in Google Search Console when asked).
- [ ] **Audience**: External, *Testing*; add yourself and any TestFlight testers as test users.
- [ ] **Data access**: add `openid`, `email`, `profile`, `.../auth/calendar.readonly` and
  `.../auth/calendar.events`. Nothing else.
- [ ] **Clients → Create client → iOS**, with the bundle ID. From the client ID
  `1234-abcd.apps.googleusercontent.com`, put `1234-abcd` in `Local.xcconfig` as
  `GOOGLE_IOS_CLIENT_PREFIX`.
- [ ] When the listing and privacy policy are ready: Audience → **Publish app**, then submit for
  verification (it asks for a demo video of the sign-in and how the data is used). Start early:
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
- [ ] Privacy policy URL (`cadence.patrick-mckinley.com/privacy`): what's read (calendars, camera
  for the pairing code, local network, Apple Music), that it goes straight to Google / Microsoft /
  your own Mac, and that there's no tracking or analytics.
- [ ] App Privacy labels: "Data not collected", matching the privacy manifest.
- [ ] Name and subtitle (have a couple of backups in case "Cadence" is taken).
- [ ] Screenshots at 6.9": desk display portrait and landscape, the full-screen alert, the Live
  Activity, widgets, pairing.
- [ ] Age rating, category (Productivity), support URL.

### 6. Before submitting
- [ ] Publish the notarized Mac DMG, so the links in the app and review notes work.
- [ ] Archive a Release build in Xcode and upload it to TestFlight. Test on your own phone, then
  external TestFlight (its beta review is a cheap dry run for App Review).
- [ ] Submit once Google verification has passed.

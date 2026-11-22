# Google OAuth verification: demo video

Google's reviewers watch this to check that each scope requested on the consent screen is actually used,
and used the way the Data access justifications say. It has to be a real recording of the production
client. Aim for 2–3 minutes, unlisted on YouTube.

Record the clips below, then `scripts/verification-video/assemble.sh` joins them, adds the captions
from `shots.txt` and the title cards, and writes one 1080p MP4.

## Before recording
- [ ] **Branding is done.** The app name on the consent screen is currently **Calendar Cadence**; the title card in
  `shots.example.txt` uses the same name, so change both if it changes.
- [ ] **Branding details.** The consent screen shows the app name, logo and links from Google Auth
  Platform → Branding, and reviewers compare them with the listing. Record after that's saved.
- [ ] **Data access lists the eight scopes** (see `ios-app-store-release.md` §2), so the consent screen
  matches the submission.
- [ ] **Use the built-in client.** A release build (or `scripts/build.sh` with `Support/Secrets.env`),
  *not* "Use my own OAuth client". The client ID in the browser must start `106641200883-`.
- [ ] **Clean consent.** At myaccount.google.com → Security → Third-party connections, remove Cadence
  for the demo account, so the consent screen lists every scope instead of "already has access".
- [ ] **Demo account:** `patrick@patrick-mckinley.com`. Keep the work account out of the video: in
  Cadence Settings → Calendars, untick its calendars for the recording.
- [ ] **A second person in the same Workspace** (a spare user on `patrick-mckinley.com`), with *no* existing
  Chat DM with you, so the video shows Cadence starting one. From that account create **"Cadence demo
  review"**, starting 5 minutes from when you'll record shot 6, with a Meet link, inviting
  `patrick@patrick-mckinley.com`. Leave it unanswered: it's also the invite for shot 3.
- [ ] Hide anything private: quit Mail/Slack, turn on Do Not Disturb, close other browser tabs, and use a
  browser window with no other signed-in accounts showing.
- [ ] Have Google Calendar (web) and Google Chat (web) open in tabs, signed in as the demo account.

Record with **⌘⇧5 → Record Entire Screen** (the browser's address bar must be visible). Save each clip
into one folder, e.g. `~/Movies/cadence-oauth/`, named as below. Pause a second or two on each
screen so the captions can be read; the trims in `shots.txt` take out dead time.

## Shots

| File | What to do | Proves |
|---|---|---|
| `01-mac-signin.mov` | Cadence → Settings → Accounts → **Sign in with Google**. In the browser, click into the address bar and scroll it so `client_id=106641200883-…` shows; hold 2 s. Pick the demo account. On the consent screen, hold until every line is readable, then **Continue**. Wait for "Cadence is connected". | Consent flow, client ID, app branding |
| `02-mac-calendar.mov` | Open the menu-bar panel. Hover/expand "Cadence demo review" so its time, Meet link and attendees show. | `calendar.readonly` |
| `03-mac-rsvp.mov` | Right-click "Cadence demo review" → **Accept**. Switch to Google Calendar (web), open the event: "Going? Yes". | `calendar.events` (RSVP) |
| `04-mac-colour.mov` | Right-click the same event → **Colour** → Tomato. Switch to Google Calendar (web) and refresh: the event is red. | `calendar.events` (colour) |
| `05-mac-chat-consent.mov` | Settings → Accounts → under the account, **Allow running-late messages…**. Consent screen shows the Chat permissions; hold, then **Continue**. | Incremental consent for the 3 Chat scopes |
| `06-mac-chat-send.mov` | Once the meeting has started (or within 15 min of it): right-click it → **Send Running Late** → it shows "Via Google Chat → *their name*"; pick a message. Switch to Google Chat (web): the new DM with the message. | `chat.spaces.readonly`, `chat.spaces.create`, `chat.messages.create` |
| `07-iphone.mp4` | Recorded from the Simulator (see below). | Same project's iOS client, calendar only |
| `08-mac-signout.mov` | Settings → Accounts → **Sign Out** → confirm. Optionally show Third-party connections no longer lists Cadence. | Revocation / user control |

### iPhone (shot 7)
Claude can drive this part: it boots the Simulator, starts `xcrun simctl io booted recordVideo`, and
taps through to **Settings → Calendars → Sign in with Google**. You type the password and approve the
consent screen, then it shows the meetings and stops recording. If you do it yourself:

```bash
xcrun simctl io booted recordVideo --codec=h264 ~/Movies/cadence-oauth/07-iphone.mp4
```
(Ctrl-C to stop.)

On a Mac behind TLS inspection (Netskope), the Simulator doesn't trust the proxy's certificate authority,
so sign-in fails with an SSL error at the token exchange. Trust it in the Simulator only:
```bash
xcrun simctl keychain booted add-root-cert "$SSL_CERT_FILE"
```

## Assemble and upload
```bash
cp scripts/verification-video/shots.example.txt ~/Movies/cadence-oauth/shots.txt
```
Edit the trims (start/end seconds per line) after watching each clip; a clip can appear on several lines,
one per caption. Then:
```bash
scripts/verification-video/assemble.sh ~/Movies/cadence-oauth
```
Upload `cadence-oauth-demo.mp4` to YouTube as **Unlisted**, and paste the link into Data access →
the video field, and the verification form.

## Afterwards
- Turn the work account's calendars back on in Cadence and sign the demo account in again.
- Delete the demo event and the Chat DM if you like.

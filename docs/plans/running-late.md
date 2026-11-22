# Plan: "Running late" messages, sent by Cadence

## What you'll see
- Once a meeting has started and you haven't joined, the full-screen alert shows a **Running late** card:
  - A suggested message, picked by the rules below, with a **2 min** delay pre-selected (alternatives: 5 and 10).
  - Where it will go, e.g. "Teams meeting chat", "Google Chat → Sam", "#design (Slack)" or "Email to 5 people".
  - Buttons: **Send**, plus a menu of your other saved messages.
- **Send** posts the message, then snoozes the alert for the delay you picked and pauses the panic/meltdown.
  When the delay runs out, the alert comes back calm.
- The same option is in the right-click menu on events and in the countdown panel.
- Nothing is ever sent without your click.

## Picking the suggestion (CadenceCore, tested)
"Previous meeting" means one that ended no more than 2 minutes before this one started, or is still running.

| Situation | Suggested message |
|---|---|
| Previous meeting still running, or your mic is in use (an overrun) | "Just wrapping up my previous meeting — there in {mins}!" |
| The same, when the previous meeting was a 1:1 and **"Mention who I'm with"** is on (off by default) | "…wrapping up with {name} — there in {mins}!" |
| Back-to-back, but the previous meeting is over and you're not on a call | "Grabbing a quick breather between back-to-backs — {mins}!" |
| Anything else | "Running a few minutes late, sorry! Be there in {mins}." |

- **Settings → Alerts → Running late:**
  - Edit the three built-in messages.
  - Add your own, using the `{mins}` and `{name}` placeholders.
  - Turn the feature off.

## Where it goes (first match wins)
1. **Teams meeting** → the meeting's own chat.
   - The chat ID comes from the join link (`19:meeting_…@thread.v2`).
   - For newer short links, it's looked up through Graph `onlineMeetings` (`chatInfo.threadId`).
   - Posted with `POST /chats/{id}/messages`.
   - Works for meetings in your own Microsoft 365 org. A client-tenant meeting falls back to email.
2. **Google Meet** → Google Chat.
   - The direct message with the organiser (`spaces:findDirectMessage?name=users/{email}`).
   - If you're the organiser of a 1:1, it goes to the other person instead.
   - Group meetings you organise fall back to email.
   - Workspace accounts only.
3. **Slack huddle** → the huddle's channel (its ID is in the link), sent with `chat.postMessage` as you.
4. **Anything else, or if the steps above fail** → email to the organiser, or to everyone invited if you're the
   organiser.
   - Sent from the account the meeting came from, through Gmail `messages.send` or Graph `sendMail`.
   - Gmail only with a user-supplied Google client (see Permissions).
   - macOS Calendar and ICS meetings use your first connected account.

## Can it all be done with API calls? (checked against current docs, 2026-11-18)
Mostly yes. Each service needs a **one-time developer setup** (done once by whoever builds Cadence, like
the existing Google/Microsoft clients). After that, users just sign in.

| Channel | Pure API? | One-time setup | Per-user |
|---|---|---|---|
| Teams meeting chat | ✅ | None. Graph v2 asks for extra scopes at sign-in, with no portal change. | Consent to `ChatMessage.Send` + `OnlineMeetings.Read`. Some tenants block user consent. |
| Find chat ID | ✅ | — | `GET /me/onlineMeetings?$filter=JoinWebUrl eq '…'` → `chatInfo.threadId`. Docs: works with "the invited attendee's user token". |
| Outlook email | ✅ | None | `Mail.Send` consent |
| Gmail email | ✅ | Own Google client only. The built-in client doesn't ask for it: publishing a restricted scope needs a yearly paid security assessment. | `gmail.send` consent |
| Google Chat DM | ⚠️ | Chat API enabled **and a Chat app configured** (name, icon, description) in the Cloud project. Console only, no API. | Business/Enterprise **Workspace accounts only**. No consumer Gmail. |
| Slack channel post | ✅ | Create one Slack app with **PKCE on**: user scope `chat:write`, localhost redirect. With PKCE there's no client secret, so the client ID can ship in the app. | Sign in with Slack through the browser. Refresh tokens expire after 30 days. A client's workspace admin may need to approve the app. |

Notes:
- The Slack docs don't say whether localhost redirects ignore the port, so Cadence uses a fixed loopback port
  for Slack.
- Turning PKCE on is one-way for a Slack app.
- Plan change: no pasted Slack token. Real "Sign in with Slack", like Google/Microsoft.
- Plan change: Google Chat is optional. If the Chat app isn't configured, or the account isn't Workspace,
  Meet meetings go by email.

## Permissions (asked for only when you turn sending on, so normal sign-in never breaks)
- **Accounts tab:** each account gets an "Allow Running-late messages" button. It re-runs sign-in with the extra scopes:
  - Google: `chat.spaces.readonly`, `chat.spaces.create`, `chat.messages.create`, plus `gmail.send` only when signed in
    through a client the user brought (Settings → Accounts → Use my own OAuth client). Accounts on the built-in client
    get no Gmail email option.
  - Microsoft: `Mail.Send`, `ChatMessage.Send`, `OnlineMeetings.Read`
- Some work tenants block these until an admin approves them. If so, Cadence says so and uses email instead.
- **Slack**: Settings → Accounts gets "Sign in with Slack", using OAuth with PKCE and a loopback redirect.
  - The token is stored in the Keychain.
  - The client ID is bundled at build time, like Google's (`SLACK_CLIENT_ID` in `Support/Secrets.env`).
- **Google Chat** also needs the Chat API enabled, and a Chat app configured, in your Google Cloud project.
  That's a one-off step for you.

## Model changes
- `Meeting.attendees: [Attendee]` (name, email, isSelf), filled in by every provider.
  This is needed for email recipients and the 1:1 `{name}`.

## Files
- **New:**
  - `CadenceCore/RunningLate.swift`: rules, templates, recipients, and Teams/Slack ID parsing.
  - `Cadence/Engine/LateMessenger.swift`: the Teams/Chat/Slack/mail senders.
  - `UI/RunningLateCard.swift`
  - Tests.
- **Changed:**
  - `Meeting` + providers (attendees)
  - `GoogleAuth` / `MicrosoftAuth` (extra-scope sign-in)
  - `Preferences`, `AccountsTab`, `SettingsView` (Alerts section)
  - `TakeoverWindow` (card + pause)
  - `AppState`, `EventRow`, `CountdownPanel` menus
  - README

## Can't verify myself
- Real sends: I'll only test against meetings you choose.
- Tenant consent behaviour.
- Google Chat app setup.
- Slack token.

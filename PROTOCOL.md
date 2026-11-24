# Cadence companion protocol

How the Cadence Mac app and the Cadence iPhone app talk to each other. The protocol is version 1
(`CompanionService.protocolVersion`).

The code is the source of truth. This document describes it:

| Topic | Where |
|---|---|
| Messages, payloads, framing | `Sources/CadenceCore/CompanionProtocol.swift` |
| Pairing code | `Sources/CadenceCore/Pairing.swift` |
| TLS parameters, channel (pings, timeout) | `Sources/CadenceShared/Companion/CompanionLink.swift` |
| Transports | `Sources/CadenceShared/Companion/CompanionTransport.swift` |
| Mac side | `Sources/Cadence/Engine/CompanionHub.swift` |
| iPhone side | `iOS/Cadence/App/CompanionClient.swift` (`CompanionClient`, `MacLink`) |

No server is involved. The two devices talk directly, and nothing leaves them.

## Overview

```
iPhone (client)                                   Mac (server)
  scan pairing QR  ◀──────── key, ids, addresses ── shows pairing code
  Bonjour browse / direct dial ─── TCP + TLS-PSK ──▶ listener (_cadence._tcp)
  hello (key id + proof) ─────────────────────────▶ checks proof
                         ◀───────────────────────── welcome, features, address,
                                                    [rekey], snapshot, [media]
  join / snooze / rsvp / … ───────────────────────▶
                         ◀───────────────────────── snapshot, alert, reminder, …
  ping ◀──────────────────── every 5 s ───────────▶ ping
  bye ─────────────────────────────────────────────▶ (or the other way)
```

- **The Mac is the server.** It holds the calendars and decides what's on. It listens and
  advertises.
- **The iPhone is the client.** It mirrors the Mac's meetings and sends the user's actions back.
- A phone can pair with several Macs, and keeps one link per Mac (`MacLink`). A Mac can have
  several phones connected at once.

## 1. Pairing

The Mac shows a pairing code: **Settings → iPhone → Show Pairing Code**. It's a QR code of a URL:

```
cadence-pair://pair?v=1&id=<macID>&name=<macName>&k=<key>&i=<keyID>&h=<host>&h=<host>&p=<port>
```

| Item | Meaning |
|---|---|
| `v` | Protocol version. |
| `id` | The Mac's stable id: a random UUID, created once. |
| `name` | The Mac's computer name. |
| `k` | A fresh 32-byte key for this one phone, in base64url with no padding. |
| `i` | Key id: 12 random bytes in base64url. Missing in codes from older Macs, which share one key with every phone (the *legacy key*). |
| `h` | Zero or more IPv4 addresses of the Mac's `en*` interfaces, with link-local addresses left out. |
| `p` | The listening port. The Mac keeps the same port across launches if it can. |

Rules:
- A code works **once**, for **15 minutes** (`CompanionKeys.inviteLifetime`).
- Showing a new code cancels the last one, and so does closing it.
- Anyone who can see the Mac's screen can pair. Nobody watching the network can, because the key
  never travels over it.
- If the link is opened from outside the iPhone app (Camera, Safari, Messages), the app asks before
  pairing.

The phone stores the key in its Keychain, one entry per Mac. It stores the Mac's id, name, key id
and addresses in its settings.

## 2. Discovery

The phone tries, in this order:
1. **Bonjour:** it browses for `_cadence._tcp` with peer-to-peer allowed, so it also finds the Mac
   over AWDL when the two aren't on the same Wi-Fi.
   - The Mac's service name is its computer name.
   - Its TXT record holds `id=<macID>`.
   - The phone connects to the result whose `id` matches. If TXT records don't resolve, it tries
     results without an id, and skips any that reject its key or welcome it with someone else's
     id.
2. **Direct dial:** if Bonjour hasn't found the Mac after **3 s**, the phone dials the Mac's saved
   addresses one at a time.
   - The phone keeps an *address book* (`CompanionAddressBook`) per Mac: the addresses from pairing
     codes and from `address` messages, grouped by network. It dials the address that worked most
     recently first.
   - It gives up on each dial after **5 s** if no `welcome` arrives.
3. If nothing has worked after about **20 s + 5 s for each saved address**, the phone suggests
   scanning a new pairing code.
4. **Bluetooth, the last resort** (`TransportPlanner`, if the setting is on and Bluetooth is
   allowed on both devices). The phone falls back when one of these is true:
   - the whole round in steps 1–3 failed;
   - there's been no Wi-Fi or wired network for **3 s**;
   - Local Network access has been off for **3 s**.

   Then it scans for the Cadence service and connects to each Mac it finds. It reads the Mac tag
   to see which paired Mac it is, then opens the L2CAP channel. Meanwhile the network keeps being
   tried. As soon as a network channel is welcomed, the phone sends `bye("upgraded")` on the
   Bluetooth channel and drops it. Joining a network, or turning Local Network access back on,
   gives the network a fresh round before Bluetooth again.

Network retries back off as 1, 2, 4, 8, 16, then 30 s. After a Bluetooth channel drops, the phone
waits 5 s before scanning again.

## 3. Transport and encryption

The network transport (`CompanionNetwork.parameters`) is:
- **TCP:** keepalive after 5 s idle, no Nagle delay, peer-to-peer allowed.
- **TLS 1.2 with a pre-shared key only.** The cipher suite is `TLS_PSK_WITH_AES_128_GCM_SHA256`.
  There are no certificates.
  - **PSK identity:** `cadence.<keyID>` for a phone's own key. The legacy shared key's identity is
    `cadence`.
  - The Mac's listener holds every key a phone may connect with: each paired phone's key, any key
    it has just sent with `rekey`, the pairing code on show, and the legacy key while a phone still
    uses it. TLS picks the key that matches the identity the phone offers.
  - The wrong key fails the TLS handshake.

The **Bluetooth transport** (`BluetoothTransport`, `BluetoothLink.swift`) carries the same frames
and messages over an L2CAP channel. TLS can't run there, so it has its own pre-shared-key
handshake.

- **Discovery:** the Mac advertises only the service UUID `7C3A1E52-4B8D-4F0A-9E61-2D5C8B0F7A13`,
  with no name. The service has two readable characteristics:
  - `…7A14`: the L2CAP PSM, as 2 bytes big-endian.
  - `…7A15`: the **Mac tag**, the first 8 bytes of `HMAC-SHA256(key: SHA256(macID), "cadence-ble-tag" ‖ hour)`.
    `hour` is the Unix time divided by 3600, as an Int64 big-endian. The phone accepts an hour
    either way.
- **The channel** is opened without Bluetooth's own link encryption, so there's no system pairing
  dialog.
- **Records:** each is a 4-byte big-endian length, then that many bytes.
- **Handshake:**
  1. Phone → Mac: `[0x01][identity length: 1 byte][identity][phone nonce: 32 bytes]`. The identity
     is the same as the TLS PSK identity.
  2. Mac → phone: `[0x01][Mac nonce: 32 bytes]`. The Mac sends this only if it holds that
     identity's key. Otherwise it closes the channel.
  3. Both derive 96 bytes: `HKDF-SHA256(link key, salt: phone nonce ‖ Mac nonce, info: "cadence-ble-v1")`.
     - The first 32 bytes are the phone→Mac key, the next 32 the Mac→phone key.
     - The last 32 are the **session binding**, which the hello `proof` signs in place of the TLS
       exporter secret.
- **After the handshake:** each record is `ChaChaPoly(ciphertext ‖ 16-byte tag)`. Its nonce is 4
  zero bytes, then a counter for that direction (UInt64 big-endian, starting at 0). A record that
  doesn't open closes the channel. Inside the records is the normal framing (§4).

The channel (`CompanionChannel`) runs the same way over either transport.

## 4. Framing

```
┌────────────────────┬──────────────────────────────┐
│ length: UInt32, BE │ body: `length` bytes of JSON │
└────────────────────┴──────────────────────────────┘
```

- One message per frame. The largest allowed body is **8 MiB**. A larger length prefix closes the
  channel.
- A frame whose body doesn't decode is **skipped**, not treated as an error. That lets a side ignore
  messages it doesn't know yet (see §8).
- JSON is Swift's `JSONEncoder` with `dateEncodingStrategy = .secondsSince1970`:
  - **Dates** are numbers: seconds since 1970, with a fractional part.
  - **`Data`** is a base64 string.
  - **`URL`** is a string.
  - **`Set`** is an array.
  - An **optional field that is nil** is left out.
- **Messages** are an object with a single key, the case name. Its value is an object of the
  case's labelled arguments. An unlabelled argument is under `_0`, and a case with no arguments has
  an empty object:

```json
{"join":{"meetingID":"ABC"}}
{"hello":{"_0":{"protocolVersion":1,"deviceID":"…","deviceName":"iPhone","displaying":false,"keyID":"…","proof":"base64…"}}}
{"ping":{}}
{"media":{}}                     // media(nil): nothing playing
```

## 5. Session lifecycle

### Handshake
1. The phone connects. TLS completes with the phone's key.
2. **Phone → Mac: `hello`.** It carries:
   - `protocolVersion`;
   - `deviceID`: a random id, created once per install;
   - `deviceName` and, optionally, `deviceModel` (for example `iPhone17,1`);
   - `displaying`;
   - `keyID` and `proof`.

   `proof` is `HMAC-SHA256(key, sessionBinding)`. The `sessionBinding` is 32 bytes of RFC 5705
   keying material exported from the TLS session with the label `EXPORTER-cadence-hello`. That ties
   the proof to this one connection, so it can't be replayed on another.
3. **The Mac checks the hello.** Until the hello passes, it ignores every other message.
   - A different `protocolVersion` gets `bye("Update Cadence on both devices …")` and the
     connection closes.
   - A `deviceID` that differs from an earlier hello on the same connection closes the connection.
   - A proof that doesn't verify against the key named by `keyID` gets `bye("This iPhone isn't
     paired with this Mac any more. Pair it again.")`.
   - The key can be the pairing code on show (not expired), a paired phone's key or offered key, or
     the legacy key.
   - A hello with no `proof` comes from an older phone. It's accepted only while the legacy key
     exists.
4. **Mac → phone, in order:**
   1. `welcome(macID, macName)`. The phone checks that `macID` is the Mac it means. If it isn't, it
      marks that endpoint as rejected and closes.
   2. `features([...])`
   3. `address(hosts, port)`, if the listener has a port.
   4. `rekey(keyID, key)`, only for a phone that proved it holds the legacy key (see §7).
   5. `snapshot(...)`, if one is available.
   6. `media(...)`, if something is playing on the Mac.

A pairing-code key becomes that phone's own key on its first hello, and the code is used up. A phone
can send `hello` again later on the same connection, for example after it's renamed. That updates its
name and keeps its place in the media-key queue.

### Keep-alive
- **Both sides send `ping` every 5 s** (`CompanionService.pingInterval`). The channel sends pings
  and swallows the ones it receives, so the app code never sees them.
- A side that hears **nothing for 15 s** (`timeout`) closes the channel with a timeout error.

### Closing
- **`bye(reason)`** closes the link politely, from either side. The receiver closes too.
- The phone sends `displayState(false)` and then `bye("background")` when it goes to the background,
  and closes 0.3 s later.
- The Mac sends `bye("stopped")` when it stops listening. The phone doesn't show that as an error.
  Any other reason is shown to the user.
- If the phone was unpaired on the Mac, the Mac sends `bye("This iPhone was unpaired on the Mac.")`.

## 6. Messages

### Phone → Mac

| Message | Fields | Meaning |
|---|---|---|
| `hello` | `_0: CompanionHello` | See §5. |
| `displayState` | `displaying: Bool` | The phone is (or isn't) in the foreground in desk mode. While any phone is displaying, the Mac stays quiet. The most recent phone to start displaying takes the Mac's media keys. |
| `join` | `meetingID` | Join this meeting on the Mac. The Mac broadcasts `dismissAlert`. |
| `snooze` | `meetingID`, `seconds: Double` | Snooze the alert. The Mac broadcasts `dismissAlert`. |
| `dismiss` | `meetingID` | Dismiss the alert. The Mac broadcasts `dismissAlert`. |
| `rsvp` | `meetingID`, `reply: RSVP?` | Answer an invite: `accept`, `tentative` or `decline`. Leaving `reply` out (nil) means "open it in Calendar on the Mac", for sources that can't RSVP. |
| `inviteLater` | `meetingID` | Close the invite pop-up without answering. |
| `resolveClash` | `key`, `choice: String?` | Settle a clash: a meeting id, `"all"`, or nil for "decide later". |
| `enrichmentAction` | `meetingID`, `action: EnrichmentAction` | `toggle(enrichmentID, itemID)`, `addEntry(enrichmentID, entry)` or `removeEntry(enrichmentID, entryID)`. |
| `joinMeeting` | `_0: Meeting` | Open a meeting this Mac may not have on its own calendars, for a phone paired with several Macs. Only sent if the Mac lists the `joinMeeting` feature. |
| `volume` | `level: Double` (0…1), `muted: Bool` | The phone's media volume, sent when it changes. Shown in the Mac's mini-player. |

### Mac → phone

| Message | Fields | Meaning |
|---|---|---|
| `welcome` | `macID`, `macName` | The hello was accepted. See §5. |
| `features` | `_0: [String]` | Optional abilities, as `CompanionFeature` raw values. Today: `joinMeeting`. |
| `address` | `hosts: [String]`, `port: UInt16` | Where to dial the Mac directly on this network. The phone adds it to its address book. It marks it as working only when the message came over the network, not over Bluetooth. |
| `rekey` | `keyID`, `key: Data` (32 bytes) | This phone's own key, used from its next connection. |
| `snapshot` | `_0: CompanionSnapshot` | The full state to mirror. Sent after the welcome, every 60 s while a phone is connected, and whenever something changes. |
| `alert` | `_0: Meeting` | The full-screen alert for this meeting is due now. |
| `dismissAlert` | `meetingID` | The alert was handled, on either side. |
| `reminder` | `_0: CompanionReminder` | A heads-up, leave, wrap-up or summary reminder, already worded by the Mac. |
| `invitePrompt` | `_0: [CompanionInvite]` | New invites to pop up. The Mac holds back its own card while a phone shows them. |
| `inviteHandled` | `meetingID` | The invite was answered, on either side. Close its pop-up. |
| `clashPrompt` | `_0: CompanionClash` | A double booking for the user to settle. |
| `clashHandled` | `key` | The clash was settled. Close its pop-up. |

### Both directions

| Message | Fields | Meaning |
|---|---|---|
| `media` | `_0: CompanionMedia?` | What's playing on the sender's side. An empty object (nil) means nothing is playing. |
| `mediaCommand` | `_0: MediaCommand` | Control the receiver's player: `play`, `pause`, `togglePlayPause`, `next`, `previous`. The Mac's volume keys can also send `volumeUp`, `volumeDown` and `toggleMute` to the phone. The Mac ignores the volume commands. |
| `ping` | none | Keep-alive. See §5. |
| `bye` | `reason: String` | Closing. See §5. |

When several phones are connected, the Mac sends to every phone that has said hello. The exception
is media traffic, which goes only to the *remote phone*: the one that most recently started
displaying, or else the one that most recently connected.

## 7. Payload types

The fields marked "older: missing" are optional. Old peers leave them out, and new peers must cope
with that.

**`CompanionSnapshot`**

| Field | Notes |
|---|---|
| `macName` | |
| `generatedAt` | Date. |
| `meetings` | `[Meeting]`: the Mac's filtered, merged and de-duplicated meetings. |
| `suppressedIDs` | Muted by a clash choice, or on an agenda-only calendar. |
| `agendaOnlyIDs` | Older: missing. |
| `takeoverEnabled` | |
| `takeoverLeadSeconds` | |
| `takeoverAutoDismissMinutes` | 0 = never. Older: missing. |
| `enrichments` | `EnrichmentBook` (`Enrichment.swift`). Older: missing. |
| `workSchedule` | `WorkSchedule` (`WorkSchedule.swift`). Older: missing. |
| `joinedIDs` | Meetings joined on this Mac. Older: missing. |

**`Meeting`** (`Meeting.swift`)

| Field | Notes |
|---|---|
| `id`, `title` | |
| `start`, `end` | Dates. |
| `isAllDay`, `isCanceled` | |
| `calendar` | `CalendarInfo`: `id`, `title`, `sourceTitle`, `color` (RGBA, 0…1), `kind`. |
| `location`, `notes`, `url` | Optional. |
| `organizer`, `organizerEmail` | Optional. |
| `attendeeCount` | |
| `attendees` | Each has `name`, `email`, `isSelf`, `isResource`. |
| `participation` | `accepted`, `declined`, `tentative`, `pending` or `unknown`. |
| `availability` | `busy`, `free`, `tentative`, `unavailable` or `unknown`. |
| `joinLink` | `service` and `url`. |
| `eventColor` | Optional. |
| `recurs` | |
| `series` | Optional. |

**Other payloads**

| Type | Fields |
|---|---|
| `CompanionReminder` | `key`, `title`, `body`, `joinMeetingID?` |
| `CompanionInvite` | `meeting`, `canRespond` (false = the source can't RSVP, so offer "open on Mac"), `conflicts?: [String]` |
| `CompanionClash` | `key`, `meetings` |
| `CompanionMedia` | `app`, `title?`, `artist?`, `isPlaying`, `artwork?`, `trackID?`, `canSkip` |
| `CompanionHello` | See §5. |

Notes on `CompanionMedia`:
- `app` is one of `system`, `appleMusic`, `spotify`, `youTubeMusic` or `podcasts`. A value the
  receiver doesn't know decodes as `system`.
- `artwork` is a small JPEG, sent only when the track changes. When it's nil, keep showing the last
  one, unless `trackID` changed.

### Keys over time
1. Older Macs gave every phone one shared key (the legacy key, identity `cadence`, no `keyID`).
2. When a phone proves it holds the legacy key (a hello with a `proof` and no `keyID`), the Mac
   creates a key for that phone alone and sends it with `rekey`. It records the key as *offered*.
3. On the phone's next connection with the new key, that key becomes the phone's own and its old
   one is retired.
4. Once every paired phone has its own key, the Mac deletes the legacy key.
5. **Forget** on the Mac deletes that phone's keys, so the phone can't connect again until it pairs
   anew.

## 8. Compatibility rules
- **`protocolVersion`** changes only for an incompatible change, and both sides refuse a different
  version. Everything else evolves without a version bump:
  - **A new optional field:** older peers ignore it. Newer peers must accept it being missing.
  - **A new message:** older peers fail to decode the frame and skip it.
    - A message the Mac must understand is sent only if the Mac lists a `CompanionFeature` for it.
      `joinMeeting` is the example.
    - Mac → phone additions are safe to send blindly, because an older phone drops them.
  - **A new enum value inside a payload:** it breaks decoding of the whole message for an older
    peer, unless that type decodes unknown values to a fallback, as `MediaApp` does. Add a fallback
    before adding values that older peers will see.
- **Don't rename** cases, labels or fields. The JSON keys are the Swift names.

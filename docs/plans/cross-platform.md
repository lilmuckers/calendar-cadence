# Plan: Windows, Linux and Android versions of Cadence

Status: idea only. Nothing here is built.

## Goal
- A **Windows** and a **Linux** desktop app that do what the Mac app does.
- An **Android** app that does what the iPhone app does.
- Any phone pairs with any desktop: Android ↔ Mac, iPhone ↔ Windows, and so on.
- The same pairing QR code, the same encrypted link and the same handoff rules as today ("the Mac goes quiet while the phone is displaying", Join opens on the desktop, Snooze and Dismiss close the alert on both).
- A look that's recognisably the same app on every platform.

## Roles
The link already has two roles, and the new platforms fit into them:

| Role | Does | Today | New |
|---|---|---|---|
| **Hub** (desktop) | Advertises the service, listens, owns the merged calendar, decides where alerts go | Mac | Windows, Linux |
| **Companion** (phone) | Finds the hub, connects, mirrors it, shows desk mode | iPhone | Android |

Wire names such as `macID`, `macName` and `PairingInvite.macID` stay as they are; they just mean "hub" from now on.

## The link as it is today (protocol v1)

| Layer | Today | Portable? |
|---|---|---|
| Pairing | QR / link `cadence-pair://pair?v=1&id=…&name=…&k=<32-byte key, base64url>&h=<host>…&p=<port>` (`Pairing.swift`) | Yes: it's a URL |
| Discovery | Bonjour `_cadence._tcp`, TXT record `id=<macID>`; falls back to dialling `h`/`p` directly | Yes: mDNS exists on every platform |
| Transport | TCP + TLS 1.2 with a pre-shared key: suite `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8), PSK identity `cadence` (`CompanionLink.swift`) | **Partly** (see below) |
| Peer-to-peer | `includePeerToPeer` (AWDL) when the two aren't on the same Wi-Fi | **No**: Apple only |
| Framing | 4-byte big-endian length, then JSON; 8 MB limit (`CompanionFraming`) | Yes |
| Messages | `CompanionMessage`, encoded by Swift's synthesized `Codable` | **Unwritten**: see below |
| Liveness | Ping both ways every 5 s; a side that hears nothing for 15 s drops the link | Yes |
| Handshake | Phone: `hello { protocolVersion, deviceID, deviceName, displaying }` → hub checks the version (`bye` if different) → `welcome` → `address` → `snapshot` | Yes |

## Problems to solve first

### 1. The message format is whatever Swift produces
`CompanionMessage` and everything inside it use compiler-generated `Codable`. That gives JSON like:

```json
{"hello":{"_0":{"protocolVersion":1,"deviceID":"…","deviceName":"…","displaying":true}}}
{"join":{"meetingID":"abc"}}
{"ping":{}}
```

Other details another implementation has to copy exactly:
- Dates are `secondsSince1970` doubles.
- A `Set` becomes an array.
- Nil optionals are left out, not sent as `null`.
- Enums are their raw strings.
- `URL` is a string.

Nothing pins this down today. Before any port:
- **`docs/PROTOCOL.md`**: frame layout, TLS settings, handshake order, and a table of every message with its direction and JSON shape.
- **Golden fixtures**: Swift tests write one JSON file per message case, plus `Meeting`, `CompanionSnapshot` and `EnrichmentBook`, into `protocol-fixtures/`. A test fails if the output changes without the fixtures being updated.
- **Every port runs the same fixtures**: it decodes each file and re-encodes it to the same JSON.
- **The same forward-compatibility rule everywhere**: skip a frame you can't decode. Swift already does this, which is why "older peers skip these" works today.

### 2. TLS with a pre-shared key isn't supported everywhere

| Library | TLS 1.2 PSK |
|---|---|
| Apple Network.framework | Yes (today) |
| OpenSSL | Yes |
| BouncyCastle `bctls` (JVM, Android) | Yes |
| Java JSSE | No |
| .NET `SslStream` | No |
| rustls | No (no external PSK for TLS 1.2) |
| Android Conscrypt | Old, deprecated hook; don't rely on it |

- **Use BouncyCastle `bctls`.** It's pure JVM and behaves the same on Android and on desktop JVM.
- A Rust or .NET implementation would go through OpenSSL bindings instead.
- A later v2 could move to TLS 1.3 PSK or Noise. It isn't needed for v1.

### 3. No AWDL off Apple
- A pair that isn't iPhone + Mac needs to be on the same network, or reachable through the direct `h`/`p` dial that already exists.
- Wi-Fi Direct between Android and Windows is possible in theory, but not worth the work.
- Say so in the pairing screen: *"Both devices need to be on the same network."*

### Small, compatible protocol additions
Older peers skip these, so none of them needs a version bump:
- **`platform` and `capabilities` in `hello` / `welcome`**: for example "can control media volume", "which players it can control", "can show a full-screen alert from the background". The hub then stops offering what the phone can't do.
- **Per-platform media players**: `MediaApp.url` is iPhone URL schemes (`music://`, `spotify://`). Each platform needs its own lookup: Android package names, a Windows app ID, a Linux MPRIS bus name.
- **Keep the strict `protocolVersion ==` check**, but be careful about bumping it once several codebases exist. Prefer new optional messages and fields.

## Stack

### Recommended: Kotlin Multiplatform + Compose Multiplatform
- One codebase for all three new targets: Android, and Windows/Linux via Compose Desktop on the JVM.
- **`core` module**: a port of `CadenceCore`, which is pure logic with good tests. It covers the protocol and framing, ICS and RRULE, deduplication, `AlertPlanner`, `AlertPolicy`, `Reminders`, `PanelPlanner`, `MeetingLinkDetector`, `CompanionRouting`, invites and enrichments.
- **`link` module**: BouncyCastle TLS-PSK for the connection, JmDNS for discovery on all three.
- **`platform` modules**: the OS integrations below, using `expect`/`actual`, JNA for Win32, and D-Bus on Linux.
- **The Apple apps stay in Swift.** To stop the two codebases drifting, the source of truth is the spec, the golden fixtures and **shared test-vector files** that both test suites run:
  - ICS samples with their expected expansions
  - Join-link detection cases
  - Alert and reminder timelines: "these meetings, this clock, expect this plan"

### Alternative: Swift everywhere
- Swift on Windows, Linux and Android, with SwiftNIO for networking.
- **For:** reuses `CadenceCore` and its tests unchanged.
- **Against:**
  - Every UI is still written natively per platform.
  - Android/JNI tooling is still rough.
  - swift-nio-ssl uses BoringSSL, and it isn't certain it offers the PSK-GCM suite. Check before choosing this route.

## Desktop hub: Windows and Linux

| Feature | Windows | Linux |
|---|---|---|
| Menu bar countdown | Tray icon. It can't show text, so draw the minutes into the icon and put the full text in the tooltip | AppIndicator / StatusNotifierItem with a label on KDE and Ubuntu. **GNOME needs an extension** |
| Floating countdown panel | Borderless, always-on-top window; Mica/Acrylic background through DWM | Works on X11. **Wayland doesn't let apps place windows or keep them on top**, apart from layer-shell on KDE and wlroots. GNOME: not possible |
| Full-screen alert | One always-on-top window per display. Windows' focus-stealing limits are manageable | Works on X11. Wayland can't take focus, so it falls back to a notification |
| Presenting detection | `SHQueryUserNotificationState` (presentation mode / busy), plus the PowerPoint slideshow window (`screenClass`) and Zoom/Teams sharing windows found through `EnumWindows` | X11: window heuristics. Wayland: effectively not possible |
| Microphone in use | Registry `CapabilityAccessManager\ConsentStore\microphone`, where `LastUsedTimeStop == 0` | PipeWire / PulseAudio source outputs |
| Calendar sources | No macOS Calendar equivalent worth using; rely on Google, Microsoft 365 and ICS directly | The same (Evolution Data Server is optional) |
| Google / Microsoft sign-in | The current loopback flow works unchanged | The same |
| Keychain | DPAPI / Credential Manager | libsecret (Secret Service) |
| Notifications with buttons | Toast notifications (need an app ID, so an installer) | libnotify actions (support varies by desktop) |
| Global join shortcut | `RegisterHotKey` | X11: `XGrabKey`. Wayland: GlobalShortcuts portal |
| Now playing | Global System Media Transport Controls: any player, with track, artwork and control (better than the Mac) | MPRIS (also good) |
| Mac media keys drive the phone | Low-level keyboard hook | Hard on Wayland |
| Travel time | Apple Maps isn't available: Google Routes, HERE or OSRM (needs an API key) | The same |
| Assistant (MCP) server | AF_UNIX sockets work on Windows 10+, or a named pipe. Client config files live elsewhere (`%APPDATA%\Claude\…`) | Unix socket, as on the Mac |
| Launch at login | `Run` registry key / Startup folder | XDG autostart |
| Running-late messages | Slack, Graph, Gmail and Google Chat are plain HTTPS: portable | The same |
| Browser profiles | Chrome, Edge, Brave, Vivaldi and Firefox profile folders exist on Windows too (different paths) | The same |

**Linux in practice:** close to full parity on X11 and on KDE. On GNOME with Wayland: no floating panel, a weaker full-screen alert, no presenting detection. Show this openly in Settings, the way **Settings → Alerts** already shows a "Right now: …" readout.

## Android companion

| iPhone feature | Android |
|---|---|
| Scan the pairing code / open the link | CameraX + ML Kit or ZXing, plus an intent filter for `cadence-pair://` |
| Its own calendars (EventKit) | `CalendarContract`: a good match, covers every synced account |
| Google / Microsoft sign-in | Custom Tabs and a redirect. Needs an **Android** OAuth client in Google Cloud (package name + SHA-1) and the redirect `msauth://<package>/<signature hash>` in the Microsoft registration |
| Desk mode while charging | `ACTION_POWER_CONNECTED` + `FLAG_KEEP_SCREEN_ON`. A `DreamService` (screensaver) is the StandBy equivalent |
| Staying connected | A foreground service of type `connectedDevice` keeps the link alive in the background, which the iPhone can't do |
| Full-screen alert from the background | Full-screen intent notification. **Android 14+ and Play policy limit this to calling and alarm apps**, so plan for a heads-up notification instead. `USE_EXACT_ALARM` is allowed for calendar apps |
| Live Activity / Dynamic Island | An ongoing notification with a countdown chronometer; Android 16's promoted "Live Updates" |
| Home Screen widgets | Jetpack Glance. Android has no real Lock Screen widgets |
| Now playing | `MediaSessionManager` with notification-listener access: any player, with track, artwork and control (better than the iPhone) |
| Let go of headphones for the Mac's call | Give up audio focus. Android can't make earbuds switch devices the way AirPods do |
| Volume, haptics | `AudioManager`, `Vibrator`: direct equivalents |
| Storing the link key | Android Keystore (through Tink) |

## Making it look like the same app
- **Design tokens:** move the colours, corner radii, type scale and urgency ramps out of `Theme.swift` into one tokens JSON file. Generate the SwiftUI and Compose themes from it.
- **Fonts:** SF isn't available off Apple. Use Inter, or the platform's default.
- **Glass:** Windows 11 Mica/Acrylic; KDE has blur; elsewhere, a solid translucent background.
- **The googly icon, moods and meltdown:** redraw them in Compose Canvas from the same vector paths, or export them as Lottie from one source.
- **Wording:** keep the strings in a shared catalog. Most reminder text is already written by the hub (`CompanionReminder`), so the phone side mostly comes for free.

## Order of work
1. **Spec and golden fixtures:** write `docs/PROTOCOL.md` and the Swift tests that produce the fixtures. Apple side only; it makes everything after it safe.
2. **Kotlin `core` + `link`:** pass the fixtures, then pair a JVM test client with the real Mac.
3. **Android companion, paired with the Mac.** Android ↔ Mac helps the most people.
4. **Windows hub**, then pair it with both phones.
5. **Linux hub:** X11 and KDE first, with reduced features on Wayland/GNOME.
6. **The `cadence-mcp` relay** for Windows and Linux.

## Risks
- **TLS-PSK library choice.** Prove BouncyCastle ↔ Network.framework interop in step 2, before building anything on top of it.
- **The unwritten JSON format.** Handled by the spec and fixtures in step 1.
- **Android's full-screen alert policy.** It could limit background alerts to a heads-up notification on Play builds.
- **Wayland.** The floating panel, the full-screen alert and presenting detection are all limited there.

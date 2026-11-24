# Plan: Bluetooth fallback for the iPhone link

## Why
The phone reaches the Mac over the network in two ways:
- **Bonjour** (`_cadence._tcp`) on the shared Wi-Fi, or over peer-to-peer Wi-Fi (AWDL) when the two
  devices aren't on the same Wi-Fi.
- **Direct dialling** of the addresses in the pairing code / address book.

Some managed Macs block both. Example: a Netskope full-tunnel VPN profile (`IncludeAllNetworks = 1`,
no `ExcludeDeviceCommunication`). It sends AWDL traffic into the tunnel. On a different network the
phone then has no route to the Mac.

Bluetooth LE isn't IP traffic, so VPNs, firewalls and proxies don't touch it. It needs no server and
no account, so no data leaves the two devices. Its range (a few metres) is about the same as AWDL's,
which the cross-network case already depends on.

## Rule: Bluetooth is the last resort
- The phone **always** tries Bonjour and every direct address first.
- Bluetooth starts only when the network is ruled out (triggers below).
- While a link is on Bluetooth, the phone **keeps trying the network** in the background. As soon as
  a network channel is welcomed, the phone moves onto it and drops the Bluetooth link.
- The Mac never starts a connection. It only advertises, so which transport gets used is the phone's
  decision alone.

### When the phone falls back to Bluetooth
Any one of these:
1. **No network round worked.** Bonjour has found nothing usable, and every saved direct address has
   had its dial this round. That's the existing `stuck` point:
   `stuckAfter + dialTimeoutAfter × addresses`, about 20–30 s.
2. **No Wi-Fi at all.** `NWPathMonitor` reports no Wi-Fi or wired interface, so Bonjour and AWDL
   can't work. Fall back after a short grace period (3 s), in case Wi-Fi is just reconnecting.
3. **Local Network access is denied** (`status == .noLocalNetwork`). Fall back after the same grace
   period. The UI keeps showing the "turn on Local Network" hint.

### How the phone moves back to the network
- Bonjour browsing and direct-dial retries keep running while the link is on Bluetooth. Retries
  back off to every 30 s at most, as they do today.
- A network attempt runs *alongside* the Bluetooth channel. Today's `channel == nil` guards become
  "no network channel".
- On `welcome` over the network, it becomes the active channel. The phone sends `bye(reason:
  "upgraded")` on the Bluetooth channel and closes it. Bluetooth scanning stops.
- If the network channel later drops, the normal order starts again: network first, then Bluetooth
  after the triggers above.

## Transport: L2CAP channel, not GATT characteristics
- The Mac's `CBPeripheralManager` publishes an L2CAP channel (`publishL2CAPChannel(withEncryption:
  false)`). We do our own encryption (below), so we don't need Bluetooth pairing, and no system
  "Pair?" dialog appears.
- The Mac advertises one fixed Cadence service UUID. That service has one readable characteristic
  holding the PSM (the L2CAP channel number), plus a **Mac tag** characteristic.
- The phone scans for the service UUID, connects, reads the tag and the PSM, then calls
  `openL2CAPChannel(psm)`.
- An L2CAP channel is a byte stream (`InputStream`/`OutputStream`). The existing length-prefixed
  `CompanionFraming` works on it unchanged, with no MTU chunking of our own. Throughput is around
  100 KB/s or more, which is plenty for snapshots, alerts and media commands.
- **Mac tag:** the first 8 bytes of `HMAC-SHA256(key: SHA256(macID), "cadence-ble" ‖ hour number)`.
  It changes every hour, so people nearby can't track a Mac by a fixed id. The phone knows each
  paired Mac's id, so it can tell which Mac is its own without trying the handshake against strangers
  (like the TXT-record match on Bonjour).

## Security: our own PSK handshake (CadenceCore, tested)
TLS can't run over a CoreBluetooth stream through Network.framework, so we use a small handshake
that gives the same protection as today's `TLS_PSK_WITH_AES_128_GCM_SHA256`. Today's TLS has no
forward secrecy either.

1. Phone → Mac: `keyID` (which key, the same as the TLS PSK identity), plus a 32-byte random nonce.
2. Mac → phone: a 32-byte random nonce. The Mac sends this only if it holds that keyID. Otherwise it
   closes the channel, like a TLS failure.
3. Both sides derive keys with HKDF-SHA256(link key, salt: both nonces, info: `"cadence-ble-v1"`):
   - a phone→Mac key and a Mac→phone key, each 32 bytes;
   - a 32-byte **session binding**, used where `sessionBinding()` (the TLS exporter) is used today.
     The existing `hello.proof` then works unchanged and is checked the same way on the Mac.
4. Each frame is sealed with ChaChaPoly. The nonce is a counter for each direction, so a replayed or
   reordered frame fails to open and the channel closes.

The Mac's fresh nonce stops replay of an old session. The proof in the hello ties the phone's
identity to this session.

## Code changes
### Shared (`CadenceShared/Companion`)
- **`CompanionTransport` protocol:** start, send `Data`, receive `Data`, close, ready/closed
  callbacks, `sessionBinding()`, and `kind` (`.network` / `.bluetooth`).
  - `NetworkTransport`: today's `NWConnection` code, moved out of `CompanionChannel` unchanged.
  - `BluetoothTransport`: the L2CAP streams plus the handshake and sealing above.
- **`CompanionChannel`** keeps framing, pings, timeout and traffic. It takes a transport instead of
  an `NWConnection`. This is the first PR, a pure refactor with no change in behaviour.
- **`LinkTraffic`** records the transport for each message, so Settings → iPhone → Advanced shows
  how much went over Bluetooth.

### Core (`CadenceCore`, unit tested)
- `BluetoothHandshake`: nonces, HKDF, per-direction sealing and opening. Tests cover round-trips, a
  wrong key, replay, reorder and a tampered frame.
- `BluetoothMacTag`: tag for an hour, and a match that allows ±1 hour for clock skew.
- `TransportPlanner`: a pure state machine for the fallback rule. Inputs are path state, Bonjour
  results, dial outcomes, the Local Network state and timers. Its output is "start/stop Bluetooth"
  plus "upgrade now". `MacLink` follows it, and the "Bluetooth only as last resort" rule is tested
  here.

### Mac (`CompanionHub`)
- `BluetoothAdvertiser` (`CBPeripheralManager`): advertises while the hub is listening and at least
  one phone is paired, or a pairing code is showing.
  - It publishes the L2CAP channel and the tag and PSM characteristics, and refreshes the tag every
    hour.
  - It hands each incoming L2CAP channel to `accept(_:)` as a `BluetoothTransport`. The hub's channel
    handling, hello checks, rekeying and snapshots stay as they are. The hub already allows several
    channels per phone, so a Bluetooth channel and its network replacement can overlap briefly.
- **Advertising doesn't depend on the network.** It costs almost nothing, and a phone only uses it
  as a last resort.
- `Support/Info.plist`: add `NSBluetoothAlwaysUsageDescription`. The app isn't sandboxed, so no
  entitlement is needed.

### iPhone (`MacLink`)
- `BluetoothScanner` (`CBCentralManager`, one shared by every `MacLink`): scans only while some
  link's planner asks for Bluetooth, and stops as soon as none does.
- `MacLink` holds an `active` channel and at most one `upgrade` attempt. It follows the
  `TransportPlanner` as described above.
- Status: `connected` gains the transport. The UI shows "Connected over Bluetooth", and the
  `needsRescan` hint stays hidden while Bluetooth works.
- `iOS/Config/Cadence-Info.plist`: add `NSBluetoothAlwaysUsageDescription`. No background mode,
  because the link already closes when the app goes to the background (`stop()` → `bye
  "background"`).
- Older phones ignore the Bluetooth advert, and older Macs don't advertise. No protocol version bump
  or feature flag is needed.

## Permission prompts
- **iPhone:** creating `CBCentralManager` shows the Bluetooth prompt. Create it at the end of
  pairing, with a sentence like "Lets Cadence reach your Mac when Wi-Fi can't". Don't create it at
  launch or in the middle of a fallback. If the user says no, the network paths keep working, and
  Settings shows that the Bluetooth fallback is off.
- **Mac:** `CBPeripheralManager` shows the prompt when a pairing code is first shown, not at launch.
- **Setting:** add **Settings → iPhone → Use Bluetooth when Wi-Fi can't connect**, on by default, on
  both the Mac and the phone.

## Order of work (one PR each)
1. Transport refactor: `CompanionTransport`, with `NetworkTransport` taken out of `CompanionChannel`.
   No change in behaviour.
2. `BluetoothHandshake`, `BluetoothMacTag` and `TransportPlanner` in CadenceCore, with tests.
3. The Mac's `BluetoothAdvertiser`, its Info.plist string and the setting.
4. The phone's `BluetoothScanner`, `MacLink` fallback and upgrade, the status text and the setting.
5. The transport in the traffic analytics, plus the README pairing section ("…or over Bluetooth when
   neither works").

## Testing
- **Unit tests:** the handshake, the tag and the planner. The planner tests check that Bluetooth
  never starts while a network path is untried, and that a welcomed network channel always replaces
  Bluetooth.
- **Real devices only:** the Simulator has no Bluetooth.
  - On this Netskope laptop with the phone on cellular or another Wi-Fi, the link should fall back to
    Bluetooth and stay connected.
  - Joining the same Wi-Fi should move the link onto the network within one retry, about 30 s.
  - Turning the phone's Wi-Fi off falls back after the 3 s grace period.
  - Walking out of range should time out (15 s) and go back to searching.
- Check that the Mac's MDM profiles (Kandji, SentinelOne) don't restrict Bluetooth peripheral mode.
  Nothing in `/Library/Managed Preferences` does so today.

## Open questions
- **Hour-based tag and clock skew:** ±1 hour covers it. Is a stable tag stored at pairing acceptable
  instead? It's simpler, but people nearby could track the Mac by it.
- **Several Macs in range on Bluetooth at once:** each `MacLink` matches its own tag, so this works.
  But one shared central serving several peripherals needs a test with two Macs.

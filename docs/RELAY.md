# iPhone access through the relay

Herdrm on iPhone reaches a Mac that has no public address (home NAT, carrier
NAT, hotel Wi-Fi) through Herdrm's relay, `wss://herdrm-relay.owo.network`.
Pairing is one QR code; there's nothing to configure on the phone.

```
iPhone ──wss──▶ relay ◀──wss── Mac (Herdrm, signed in to the relay)
   └──────── Noise IKpsk2 session ────────┘
              └── SSH to the Mac's own sshd (127.0.0.1:22) ──┘
```

The relay server is a separate, private project. Everything the apps do is
here; the server can't read or change any of it.

The relay is the fallback. A server with a public IP or hostname (a VPS, a
machine with port forwarding) is added on the iPhone directly with Add Device →
Direct, signing in with your own SSH keys (Keys). A Mac that has a public
address but pairs by QR can give it in Settings → iPhone: the phone tries it
first and uses the relay only when that fails, accepting the direct route only
if sshd presents the host key the Mac reported over the encrypted channel.

## Using it

1. On the Mac, turn on **Remote Login** (System Settings → General → Sharing).
2. In Herdrm on the Mac: **Settings → iPhone → Allow Herdrm on iPhone**, then
   **Pair iPhone…**.
3. On the iPhone: **Add Device → Pair with Mac → Scan** (or scan with the
   Camera app). The code works once and expires after 10 minutes.

## Security

- **End-to-end encryption.** `Noise_IKpsk2_25519_ChaChaPoly_SHA256`
  (`Packages/HerdrKit/Sources/HerdrKit/RelayNoise.swift`), checked byte for byte
  against the relay's Go reference in `RelayNoiseTests`. The phone learns the
  Mac's static key from the QR code, so a relay can't pose as the Mac.
- **Pairing secret.** The code carries a one-time 32-byte PSK. A phone without
  it can't complete the handshake. The Mac records a new phone only after the
  phone's first encrypted message proves it holds the PSK.
- **Host identity at the relay.** The Mac proves it owns its relay id with an
  Ed25519 signature, so nobody else can take its slot.
- **SSH on top.** Inside the session the phone runs ordinary SSH to the Mac's
  own sshd, with its device key. Pairing installs that key as
  `from="127.0.0.1,::1" ssh-ed25519 … herdrm-relay:<phone>`, which works only
  through the Mac's own end of the relay. The Mac also reports its SSH host key
  over the encrypted channel, and the phone checks sshd against it.
- **Keys.** The Mac's keys and each phone's PSK are in the Keychain; the phone
  list is `~/Library/Application Support/HerdrM/relay-phones.json` (no secrets).
  Removing a phone in Settings → iPhone deletes its PSK and its
  `authorized_keys` line.
- **What the relay sees.** Which Mac ids are online, when phones connect, and
  frame sizes and timing. No names, keys, credentials or content.

## Code

| Where | What |
|-------|------|
| `HerdrKit/RelayNoise.swift` | the Noise handshake and transport ciphers |
| `HerdrKit/RelayProtocol.swift` | host ids, the pairing link, session messages |
| `HerdrKit/RelayTransport.swift` | relay WebSocket, encrypted stream, byte pump, phone client |
| `HerdrKit/RelayHost.swift` | the Mac: registration, pairing, phones, `authorized_keys`, forwarding to sshd |
| `HerdrSSH` `SSHConnection.connect(overDescriptor:)` | SSH over a socketpair the relay session pumps |
| `HerdrM/RelaySettingsView.swift` | Settings → iPhone, the pairing sheet |
| `HerdrMobile/MobileRelay.swift`, `MobilePairingView.swift` | pairing and the relay device on iPhone |

## Tests

```sh
cd Packages/HerdrKit && xcrun swift test --filter Relay   # vectors + live relay
```

`RelayEndToEndTests` pair, reconnect, re-pair, expire and revoke through the
deployed relay (`HERDRM_SKIP_RELAY_E2E=1` skips them offline).
`RelaySSHEndToEndTests` run the stock `ssh` client through the relay against
a disposable user-level sshd (`HERDRM_RELAY_SSHD_PORT`,
`HERDRM_RELAY_SSHD_AUTHKEYS`). Neither touches the system sshd or
`~/.ssh`. HerdrSSH's `DescriptorConnectionTests` run on the iOS Simulator.

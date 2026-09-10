# herdrm — HerdrM

Native macOS console for [herdr](https://herdr.dev) (the terminal workspace manager for
coding agents). Sidebar lists Spaces (herdr workspaces) and Agents; the bottom-left
footer switches devices (Local + remote herdr hosts over SSH); the right pane is a pure
embedded terminal running `herdr agent attach` — no chat composer.

Design canvas (waku-style sidebar, light/dark): `design/` — published as the
"Herdr for Mac" artifact. `design/canvas.json` notes carry the design tokens and specs.

## Layout

- `Packages/HerdrKit` — SPM library (macOS + iOS): NDJSON-over-Unix-socket RPC
  (`SocketRPC`), models, `Device`/`DeviceStore` (persisted to
  `~/Library/Application Support/HerdrM/devices.json`). macOS-only files are
  `#if os(macOS)`-gated: `SSHTunnel` (OpenSSH forward), `HerdrService` facade,
  `ShellEnvironment`, `LocalServer`, `DeviceFileService`, `SSHCredentialStore`.
- `Packages/HerdrSSH` — SPM library (iOS 18+): libssh2 + OpenSSL as prebuilt
  arm64 xcframeworks (`Artifacts/PROVENANCE.md`), ported from Heeler's
  HeelerSSH. `SSHConnection` does `direct-streamlocal` to the remote herdr
  socket (one channel per RPC), PTY exec channels for terminal attach.
- `Sources/HerdrM` — macOS SwiftUI app (XcodeGen `project.yml`). The terminal is
  libghostty (`GhosttyTerminal` product of Lakr233/libghostty-spm, Metal): each
  pane is a host-managed `InMemoryTerminalSession` fed by `TerminalProcess`, a
  local `forkpty` byte pump. `LineBreakTerminalView` subclasses ghostty's
  `AppTerminalView` and keeps herdrm's own behavior (light-mode ANSI adapter,
  ⌘-editing-key readline chords via `session.sendInput`, agent-aware paste).
- `Sources/HerdrMobile` — iOS/iPadOS SwiftUI app (`HerdrMobile` target, iOS 18,
  iPhone + iPad). Devices are SSH hosts (Ed25519 device key in Keychain or
  password; TOFU host keys); RPC over `HerdrSSH`; terminal is the same libghostty
  `InMemoryTerminalSession`, fed by the SSH PTY channel, display-first behind an
  APC bootstrap marker + native composer (`agent.prompt`) + key bar
  (`pane.send_input` keys). No relay yet — a second `MobileTransport` later.
- `design/` — design canvas working files (`*.dc.html` artboards + `canvas.json`).

## Build & test

```sh
make build      # xcodegen + xcodebuild → build/Build/Products/Debug/HerdrM.app
make run
make kit-test   # HerdrKit integration tests (need a running local herdr)
HERDRM_E2E_SSH_TARGET=vincent@10.10.10.87 make kit-test   # + remote SSH E2E
```

xcodebuild needs `-skipPackagePluginValidation`; the Makefile passes it. Building
against Xcode 27 needs the Metal toolchain component (libghostty compiles a Metal
shader): `xcodebuild -downloadComponent MetalToolchain` once.

## Release

Repo: github.com/missuo/herdrm. Push a `v*` tag → `.github/workflows/release.yml`
builds Release (Developer ID: MOE AI LLC, hardened runtime), notarizes via
notarytool, staples, Sparkle-signs the zip, generates `appcast.xml`, and
publishes both as a GitHub release. Secrets: MACOS_CERTIFICATE_P12/_PASSWORD,
APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD, SPARKLE_PRIVATE_KEY (EdDSA private
key also lives in the local login Keychain; public key is pinned in project.yml).
Sparkle feed: the release asset `appcast.xml` at `releases/latest/download/`.
Versioning: MARKETING_VERSION from the tag, CFBundleVersion = CI run number.
CHANGELOG.md is mandatory: CI extracts the `## [x.y.z]` section for the GitHub
release notes and the Sparkle update description, and fails if it's missing —
add the section before tagging. The cask in OwO-Network/homebrew-brew is
auto-bumped after each release.

## herdr protocol notes (0.9.0, private protocol 22; verified against the live socket)

- Requests are NDJSON `{"id","method","params"}` on `~/.config/herdr/herdr.sock`;
  `params` must be present even when empty (`{}`), or the server rejects the request.
- `tab.create` returns the new pane as `result.root_pane.pane_id`.
- `events.subscribe` takes `{"subscriptions":[{"type":"pane.updated"},…]}`.
  `pane.agent_status_changed` is pane-scoped and must be subscribed with `pane_id`;
  status transitions do not emit `pane.updated`. HerdrM appends one scoped status
  subscription for every known pane and re-subscribes when pane topology changes.
  `pane.scroll_changed` / `pane.output_matched` are scoped too.
- Terminal attach: agents use `herdr agent attach <pane_id> --takeover`; bare shells use
  `herdr terminal attach <terminal_id> --takeover` (takes the pane over from other attached
  clients). Remote devices run it through `ssh -tt` with PATH prepended
  (`sshd` exec is not a login shell; herdr lives in `/opt/homebrew/bin` on macOS hosts).
- Agent status buckets sort Blocked > Done > Working > Idle (matches Heeler).

Reference repos: `~/Projects/herdr` (server source), `~/Projects/Heeler` (iOS client,
same domain model), `~/Projects/waku` (sidebar design reference).

<p align="center">
  <img src="Resources/AppIcon/herdrm-icon-rounded.png" width="128" alt="herdrm icon" />
</p>

<h1 align="center">herdrm</h1>

<p align="center">
  A native macOS console for <a href="https://herdr.dev">herdr</a> — see every coding agent
  across all your machines, and jump straight into its live terminal.
</p>

---

> [!WARNING]
> Early stage software without full test coverage — expect bugs. PRs are very welcome!

<p align="center">
  <img src=".github/assets/screenshot.png" alt="herdrm — device switcher and a live claude terminal" />
</p>

## What it does

[herdr](https://herdr.dev) is the runtime your coding agents live on: a background
server that owns their terminals, keeps them running, and knows which one is
working, blocked, or done. **herdrm** puts a native macOS window on top of it:

- **All your devices, in parallel** — local herdr plus any number of remote
  machines over SSH (the remote socket is forwarded through `ssh -L`, so
  everything works identically). Every device stays connected with automatic
  reconnect; the sidebar aggregates them all, with a tinted name chip marking
  where each row lives, and the bottom-left switcher filters by device.
- **Spaces & Agents sidebar** — every herdr workspace and every agent
  (claude, codex, gemini, grok, opencode, …) with live status: blocked agents
  bubble to the top, working ones spin, done ones get a check.
- **Live terminal** — selecting an agent attaches directly to its PTY
  (`herdr agent attach`). Full TUI, precise cursor, no chat wrapper.
- **Notifications** — a system notification when any agent on any device
  finishes or needs your input; clicking it jumps straight to that agent.
  Agents you're actively watching never notify.
- **New Agent** — starts an agent in any space on any device. The picker only
  offers CLIs actually installed on that device, and enables each agent's own
  bypass-permissions flag by default (e.g. `--dangerously-skip-permissions`
  for claude).
- **Search** — ⌘K command palette across agents and spaces on every device.
- **Light & dark**, auto-updates via Sparkle, signed and notarized.

## Requirements

- macOS 14+
- [herdr](https://herdr.dev) installed locally (herdrm starts the local server
  itself if it isn't running) and running on your remote machines
- For remote devices: OpenSSH access through your SSH config/agent, Tailscale
  SSH, or a password stored in the macOS login Keychain

## Install

### Homebrew

```sh
brew install owo-network/brew/herdrm
```

### Manual

Download the latest `herdrm-x.y.z.zip` from
[Releases](https://github.com/missuo/herdrm/releases), unzip, and drag
`herdrm.app` into `/Applications`. Either way the app updates itself from then on.

## Build from source

```sh
brew install xcodegen
make build   # xcodegen + xcodebuild → build/Build/Products/Debug/herdrm.app
make run
make kit-test  # HerdrKit integration tests (needs a running local herdr)
```

## Architecture

- `Packages/HerdrKit` — Swift package: NDJSON-over-Unix-socket RPC client for
  the herdr socket API, SSH tunnel management, device store.
- `Sources/HerdrM` — SwiftUI app; the terminal embed is
  [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Credits

- [herdr](https://herdr.dev) — the terminal workspace manager for coding
  agents that this app is a console for.
- [Heeler](https://github.com/ZingerLittleBee/Heeler) — the iOS herdr client;
  herdrm borrows its domain model and transport patterns.
- [waku](https://github.com/egoist/waku) — the sidebar design reference.
- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) — terminal emulation.
- [Sparkle](https://sparkle-project.org) — auto-updates.
- [Lobe Icons](https://github.com/lobehub/lobe-icons) and
  [Simple Icons](https://simpleicons.org) — agent and OS brand icons.

## Star History

<p align="center">
  <a href="https://star-history.com/#missuo/herdrm&Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date&theme=dark" />
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date" />
      <img src="https://api.star-history.com/svg?repos=missuo/herdrm&type=Date" width="600" alt="Star History Chart for missuo/herdrm" />
    </picture>
  </a>
</p>

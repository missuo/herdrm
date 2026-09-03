# Changelog

All notable changes to herdrm are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com); versions follow semver.
Release automation extracts the matching section for GitHub release notes and
the Sparkle update description — a release without a section here fails CI.

## [Unreleased]

### Added
- Double-click a Space, Agent, or herdr Terminal in the sidebar to rename it
  (same sheet as the context menu). Terminals now rename via `tab.rename`, and
  a user-set tab label wins over the OSC title so the new name is visible.
- herdr Terminals in the sidebar can be drag-reordered. The drop calls the
  same `tab.move` path as Agents; cross-space drops are ignored. Standalone
  shells stay in creation order. Drag uses snapshot array order (the
  `insert_index` herdr actually applies), not tab `number`. Rows slide into
  place and the dragged row follows the pointer.

### Fixed
- After `tab.move`, a leftover numeric tab label (`"2"` on tab number 1)
  is no longer treated as a display name, so Agents keep their real title.

## [0.5.3] - 2026-08-29

### Added
- Pasting images and files into an attached terminal now works for Cursor,
  Gemini, Grok, OpenCode, and pi, alongside the existing Claude Code, Codex,
  and Copilot support. On a local device an image on the clipboard forwards
  Ctrl+V so the agent attaches the pixels itself; on an SSH device the image
  or file is staged on that host and its path is pasted. (#61, thanks
  @ljxw88!)
- Settings → Agents can now override the binary path for pi. (#61, thanks
  @ljxw88!)
- Sidebar Spaces and Agents share one set of conversation marks: a spinner
  while running, a filled unread dot after a finish you have not opened,
  nothing once viewed, and an exclamation if the agent needs input. A space
  shows the strongest state among its agents. (#60, thanks @JackieJam!)
- Agents in the sidebar can be drag-reordered. The drop calls herdr's
  `tab.move` (same RPC the TUI uses) so the order is the session's, not just
  this window. Cross-space drops are ignored. ⌘K still ranks by urgency.
  (#60, thanks @JackieJam!)

### Fixed
- Kimi and pi rows show their bundled brand icon instead of no icon at all —
  both marks shipped in the app but were missing from the icon lookup. Kinds
  that only match a prefix ("claude-code-next") now resolve to the longest
  matching mark rather than an arbitrary one, and only on a `-` boundary so a
  two-letter kind like `pi` can't claim an unrelated name such as `pilot`.
  (#61, thanks @ljxw88!)
- Powerline prompt separators render correctly in light mode: a separator's
  foreground is the neighboring segment's background, so the adapter now
  applies the background transform to it instead of the text-contrast
  transform that made joins look dark and blended. (#63, #64, thanks
  @hualinli!)

## [0.5.2] - 2026-08-28

### Added
- Bare herdr shell panes now appear under TERMINALS alongside agents and can
  be attached on local or SSH devices (`herdr terminal attach`). **New
  Terminal** (⌘T) creates a persistent shell tab in a chosen device and space.
  (#57, #58, thanks @forcey!)
- Standalone terminals — app-owned shells outside any herdr space — can now
  connect to any configured device over SSH as well as opening a local login
  shell, reusing the device's OpenSSH config, agent, host-key, and Keychain
  password flow. Pick "Standalone" in the New Terminal sheet. (#54, thanks
  @ljxw88!)
- A two-pane Files workspace browses local and SSH-device files and copies
  regular files in either direction with progress, cancellation, atomic
  staging, and Replace / Keep Both conflict handling. (#55, thanks @ljxw88!)

### Fixed
- Rename Agent now sets the herdr tab label (`tab.rename`) instead of
  `agent.rename`. Tab labels accept Chinese, spaces, and punctuation; agent
  identifiers do not (`[a-z][a-z0-9_-]{0,31}`). The sidebar shows that label.
  (#59, thanks @JackieJam!)
- Remote terminal attaches now inherit the captured shell environment, so
  OpenSSH keeps the user's `PATH` and `SSH_AUTH_SOCK` when evaluating SSH
  configuration and agent-backed identities. (#56, thanks @OnkayC!)

## [0.5.1] - 2026-08-27

### Added
- Agents can be renamed from the sidebar context menu (`agent.rename`). The
  row then shows that name instead of a stale terminal title. (#53, thanks
  @JackieJam!)

### Fixed
- Sidebar agent rows no longer treat a terminal OSC title as the display name
  when it is just the agent kind or the project folder. Cursor / OpenCode
  conversation titles still win when the herdr name is auto-generated; Agy
  and Codex fall through to the herdr name so a rename is visible. (#53,
  thanks @JackieJam!)
- Pasting a copied image file into a local agent behaves like pasting a
  screenshot again: agents that read clipboard images natively (Claude Code,
  Codex, Copilot) get the paste shortcut and show their [Image #1]-style
  attachment, instead of a shell-quoted file path. 0.3.9's agent-aware paste
  had routed every copied file — image or not — through the path paste;
  non-image files keep it, and remote devices still upload and paste the
  remote path.

## [0.5.0] - 2026-08-27

### Added
- Simplified Chinese localization via an Apple String Catalog, with Settings →
  Appearance offering Follow System / English / Simplified Chinese (restart to
  apply). (#46, #52, thanks @eachann1024!)

### Fixed
- ⌘⌫ in the terminal now deletes to the start of the line (^U). ⌘← / ⌘→ jump
  to start / end (^A / ^E) and ⌘⌦ deletes to the end (^K), with the matching ⌥
  word-editing chords; the same chords still send those readline bytes when a
  TUI has negotiated the kitty keyboard protocol. zsh's default ^U is
  kill-whole-line — that binding lives in the shell, not the terminal. (#49,
  thanks @eachann1024!)
- Sidebar section headers (Spaces, Agents, Terminals) now collapse on click,
  and chrome buttons no longer keep a focus ring after click. (#48, #50,
  thanks @eachann1024!)
- CJK IME composition in the embedded terminal keeps preedit visible, holds
  the candidate window at the caret, and does not forward edit shortcuts to
  the PTY. (#47, #51, thanks @eachann1024!)
- The app icon renders with proper rounded corners and margins in the Dock and
  ⌘Tab on macOS 15 and earlier — releases now compile the Icon Composer icon
  so down-level variants are generated instead of the full-bleed square. (#44,
  thanks @hualinli!)
- A write to a peer-closed herdr socket can no longer take the whole app down
  with SIGPIPE — connections opt out of the signal and the reconnect path
  handles the error instead. (#45, thanks @csorodrigo!)

## [0.4.5] - 2026-08-23

### Changed
- With a single device selected in the bottom-left switcher, the Space and
  Agent rows (and the titlebar) no longer show that device's badge — every
  row belongs to it, so the badge said nothing. ⌘K search keeps its badges
  (it always searches every device), and the New Agent / New Space device
  pickers stay available while filtered.

## [0.4.4] - 2026-08-23

### Added
- The device filter (bottom-left switcher) is remembered across launches:
  reopening herdrm restores the device you had selected instead of always
  starting on All Devices. Removing that device falls back to All Devices.

## [0.4.3] - 2026-08-23

### Fixed
- Light mode no longer inverts the output of agents that are themselves in a
  light theme. The adapter used to flip every explicit background on the
  assumption that agent output is dark-themed, which turned a light-themed
  Claude Code's pale message bars and diff backgrounds into black strips with
  dark (unreadable) text. Backgrounds now flip only when they are actually
  dark; dark-themed output (Codex's input box, dark diff colors) behaves as
  before.

## [0.4.2] - 2026-08-22

### Fixed
- Text selected in the terminal while an agent is streaming output no longer
  flickers away the instant it is made — the selection now survives incoming
  output and only clears when you click elsewhere. (#43, thanks @ljxw88!)

## [0.4.1] - 2026-08-22

### Fixed
- Dragging a Space in the sidebar actually reorders it. The 0.4.0 rows were
  SwiftUI `Button`s, and on macOS that swallows mouseDown so `.onDrag` never
  started (click-to-select still worked). Space rows now use an AppKit drag
  session after a few points of movement.
- New Agent (and local `herdr` lookup) no longer trust the Finder-launched
  app's sparse PATH. herdrm captures the login + interactive shell environment
  once in the background (`zsh -i -l`, then `-l` if the interactive rc hangs),
  via `env -0` into a private tempfile so rc banners cannot pollute the
  snapshot. Lookup walks that PATH, then the GUI PATH, then well-known
  prefixes (Homebrew, bun, cargo, mise, volta). Spawn and terminal attach
  reuse the same environment and PATH, so a `#!/usr/bin/env node` shim that
  shows as installed can actually find `node`. Settings → Agents accepts a
  per-kind binary path when detection is wrong. SSH devices still follow the
  remote server's manifest catalog.

## [0.4.0] - 2026-08-22

### Added
- Split the terminal to run a local login shell beside the agent: **⌘D**
  splits vertically, **⇧⌘D** horizontally, the divider drags with a persisted
  ratio, and ⌘W closes the split before it closes anything else. The active
  pane keeps full color while the inactive one dims; **⌥⌘ arrows** move focus
  directionally and **⌃⌘ arrows** resize in 5% steps. (#36, #37, thanks
  @alejodelosrios!)
- **New Terminal** in the sidebar opens a standalone local shell as its own
  entry under a TERMINALS section — full pane, selectable like an agent, and
  it keeps running while you switch away. Every click opens another one;
  close from the context menu, with ⌘W, or by exiting the shell.
- Spaces in the sidebar can be drag-reordered. The drop calls herdr's
  `workspace.move_block` (same RPC the TUI uses) so the order is the
  session's, not a herdrm-only list; worktree groups move as a block.
  Cross-device drops are ignored. (#38, #39, thanks @kkunkunya!)

### Fixed
- Nerd Font icons in agent TUIs (pi's powerfooter, powerline prompts) no
  longer render as tofu boxes: herdrm now bundles the Nerd Fonts symbols font
  (MIT) and resolves icon glyphs through it for every terminal font, without
  touching emoji or CJK fallback. (#34)

## [0.3.9] - 2026-08-21

### Changed
- Attachment paste is now agent-aware: Codex joins Claude Code and Copilot,
  pasting a Finder file into a local agent inserts its (shell-quoted) local
  path instead of uploading, and remote paths are shell-quoted too so spaces
  survive. Which agents take attachments now comes from a capability registry
  that herdr's agent manifests can drive once they advertise it — with
  today's servers, a built-in fallback covers the three known CLIs. (#33,
  thanks @ljxw88!)

## [0.3.8] - 2026-08-20

### Added
- Terminal legibility settings: **Thin strokes** (on by default) turns off the
  macOS font smoothing that thickens glyph stems and makes agent output —
  Claude Code's bold text especially — look heavy and smudged; **Weight**
  (Light/Regular/Medium) for the system monospaced font; and **Line spacing**
  (100%–140%). (#27, thanks @alejodelosrios!)
- ⌘K now lists agents in the same order as the sidebar — the ones waiting on
  you first, then done, working and idle — and each row carries its status
  glyph plus a "needs input" label. (#29, thanks @alejodelosrios!)

### Fixed
- Jumping to an agent — from ⌘K, the sidebar, or a notification — now leaves
  the keyboard focus in its terminal. It used to take a mouse click before you
  could type. (#28, thanks @alejodelosrios!)
- The ⌘K result list scrolls to follow the keyboard selection instead of
  letting it walk out of view; typing a new query or reopening the sheet
  returns to the top. (#30, thanks @alejodelosrios!)
- The New Agent picker now finds CLIs installed by NVM (and Grok's user-level
  installer) when herdrm starts outside a login shell, locally or over SSH —
  agents like `pi` installed via npm under NVM show up in the picker. (#31,
  #32, thanks @JackieJam!)
- Actions fired while a device is disconnected no longer fail with the bare
  "connection failed: not connected": the alert now says which device is
  unreachable and why — still connecting, or the reconnect loop's actual
  error. (#21)

## [0.3.7] - 2026-08-20

### Added
- Intel Macs are supported: releases are now universal binaries (arm64 +
  x86_64) and the Homebrew cask no longer requires Apple Silicon. (#12, #26,
  thanks @Yuxin-Qiao!)
- Paste files and images straight into a Claude Code or Copilot pane. On a
  remote device the file is streamed over SSH into a private cache under
  `~/.cache/herdrm/attachments` (0700, entries dropped after seven days) and
  its remote path is pasted into the agent; on a local device the paste is
  forwarded as Ctrl+V so the agent reads the clipboard itself. Uploads are
  capped at 50 MB and show an indicator while they run. (#25, thanks
  @ljxw88!)

### Fixed
- A dead terminal session no longer freezes on its last frame while eating
  input: a dropped SSH connection or a takeover by another client now covers
  the pane with an explanation and a Reconnect button, and the attach SSH
  carries the same keepalives as the tunnel so dead paths are noticed within
  ~45 s. (#23, thanks @lcandy2!)
- Settings → Terminal: the preview no longer sits indented by the form's label
  column, and the mouse-reporting description no longer truncates.

## [0.3.6] - 2026-08-20

### Fixed
- Terminal attach no longer fails with `protocol_mismatch` when the machine
  has more than one herdr binary (a stale copy earlier in the PATH than the
  one the server runs): the attach now picks the binary whose version matches
  the server's, falling back to the first one found. herdr's attach stream
  requires exact protocol equality — 0.8.0 speaks 19, 0.8.2 speaks 20 — while
  the sidebar's control API tolerates the skew, which is why everything else
  kept working. (#22)

### Added
- The New Space sheet's DIRECTORY field now carries an inline folder browser:
  type freely, click a folder to descend, arrow-up to the parent, and typing a
  partial name filters the listing as you go. Works on remote devices too
  (listed over one-shot SSH); local devices keep the native Browse… panel.
  (#20, thanks @lcandy2!)

## [0.3.5] - 2026-08-20

### Added
- Custom SSH ports: enter the device target as `user@host:port` (or an
  `ssh://` URI); plain targets and `~/.ssh/config` aliases work as before.
- Right-click context menu in the terminal: Copy, Paste, Select All — plus
  Open Link and Copy Link Address when the selected text contains a URL
  (double-click selects a whole URL). (#19)
- ⌘-click opens http(s) links under the pointer in the default browser
  (SwiftTerm's built-in link detection; hold ⌘ to highlight). (#19)

## [0.3.4] - 2026-08-20

### Added
- Dragging in the terminal now selects text locally, like a native text view —
  no Shift needed — and a plain click dismisses the selection; copy with ⌘C.
  Clicks and the scroll wheel still reach the TUI. Previously herdr's attach
  stream captured every mouse event (including Shift+drag via XTSHIFTESCAPE),
  so nothing could be selected or copied at all. (#17)

### Fixed
- Connecting to a remote whose herdr isn't running used to fail with
  `malformed response: empty reply` — the tunnel comes up fine and ssh only
  reports the forwarding failure after a client uses the socket. herdrm now
  diagnoses this in two steps: a remote probe that turns the common case into
  "herdr isn't running on <host> — start it by running \"herdr\" on that
  machine" (and tells a stale socket or sshd's AllowStreamLocalForwarding
  apart from it), with ssh's continuously captured stderr as the fallback for
  everything else. (#16, thanks @0xrsydn! #18, thanks @lcandy2!)

## [0.3.3] - 2026-08-20

### Fixed
- Light mode now also adapts 256-color output — Claude Code's diff and header
  backgrounds arrive as indexed colors (`48;5;n`), which the 0.3.2 filter
  didn't cover, so they stayed dark. Foregrounds that are already readable on
  white keep their color; only backgrounds flip.

## [0.3.2] - 2026-08-20

### Fixed
- Terminal colors now adapt to Light mode: explicit truecolor output (like
  Codex's dark input box) is luminance-flipped before it reaches the terminal,
  and the ANSI palette follows the theme. (#15, thanks @hhmy27!) On top of
  that, palette entries that already read well on white — red, blue, magenta,
  black — keep their original colors instead of washing out to pastels.

## [0.3.1] - 2026-08-20

### Added
- herdrm now starts the local herdr server itself when nothing is listening on
  the socket, instead of asking you to go run `herdr` in a terminal. (#8,
  thanks @FacuVCanale!)
- Shift+Enter in the agent terminal inserts a line break instead of submitting
  — sent as ESC+CR, which coding-agent TUIs already understand. Inert when a
  TUI negotiates the kitty keyboard protocol (it already distinguishes the
  modifier). (#14, thanks @ccyisafool!)
- File menu commands with keyboard shortcuts: **New Agent** (⌘N) and **New
  Space** (⇧⌘N), reachable while the focus is inside an agent's terminal.
  ⌘N replaces *New Window* — herdrm is a single-window console, so a second
  window would only duplicate the device tree. (#10, thanks @alejodelosrios!)

### Fixed
- SSH tunnels are torn down when the app quits. Each launch used to leave its
  `ssh` processes running (reparented to `launchd`) and their forwarded sockets
  in place, so tunnels piled up across quit/relaunch cycles. (#11, thanks
  @alejodelosrios!)

## [0.3.0] - 2026-08-19

### Added
- SSH password authentication as a fallback: when keys/agent/Tailscale SSH
  can't authenticate, herdrm prompts in-app and stores the password in the
  macOS login Keychain — never in files or process arguments. (#3, thanks
  @ljxw88!)
- SSH failures now surface OpenSSH's actual error text instead of a bare
  exit code. (#3)
- Notification sounds: a chime when an agent finishes (Glass) or needs input
  (Funk), independent of banner delivery; toggle in Settings → Notifications.
- Settings → Notifications now shows the system permission status, with
  one-click request or a shortcut to System Settings when denied.

### Fixed
- Starting an agent right after creating its pane no longer fails with
  `agent_pane_busy` while the shell is still initializing — herdrm now waits
  like the herdr CLI does. (#3)

## [0.2.3] - 2026-08-19

### Added
- Spaces can now be renamed from the sidebar context menu. (#6, thanks
  @hhmy27!)

## [0.2.2] - 2026-08-19

### Added
- Terminal settings: "Mouse reporting" toggle — turn it off to always select
  text with the mouse even in TUIs that capture the mouse (Shift-drag selects
  either way). (#2, #5)

### Fixed
- The terminal now re-renders immediately when the app theme changes. (#4)

## [0.2.1] - 2026-08-19

### Fixed
- OS detection for newly added devices now retries on every successful
  connection instead of only once at add time, and SSH auto-accepts unknown
  host keys (`accept-new`) so a fresh device's first connection no longer
  fails before you've ssh'd to it manually.

## [0.2.0] - 2026-08-19

### Added
- All devices now stay connected in parallel: the sidebar aggregates spaces and
  agents across every machine, with a small OS badge marking where each row
  lives. The bottom-left switcher became a filter (All Devices by default).
- Notifications now watch every connected device, not just the selected one;
  clicking a notification jumps straight to that agent.
- New Agent and New Space gained a device picker; installed-agent sniffing is
  cached per device.
- Per-device connection health with automatic reconnect (1s → 30s backoff).

### Changed
- Search results show device badges and search across all devices.

## [0.1.2] - 2026-08-19

### Added
- New Space now has a directory picker (Browse… locally, `~`-expansion on
  remote devices) and an optional name field.

## [0.1.1] - 2026-08-19

### Fixed
- Crash when opening the device switcher on macOS 26+ betas: replaced the
  NSPopover with an in-window panel (uncaught NSRemoteView exception in
  ViewBridge).

## [0.1.0] - 2026-08-19

### Added
- Initial release: waku-style sidebar with spaces and agents, device switcher
  with SSH remotes, SwiftTerm PTY attach, agent sniffing with bypass-mode
  flags, ⌘K search, Sparkle auto-updates, signed and notarized releases.

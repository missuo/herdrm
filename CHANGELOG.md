# Changelog

All notable changes to herdrm are documented in this file. The format is based
on [Keep a Changelog](https://keepachangelog.com); versions follow semver.
Release automation extracts the matching section for GitHub release notes and
the Sparkle update description — a release without a section here fails CI.

## [Unreleased]

### Added
- **⌃Tab switches to recent agents and terminals, like ⌘Tab (#156).** One
  tap goes back to the agent or terminal you were just in, and tapping again
  flips back. Hold ⌃ and keep pressing Tab to show the list, most recently
  used first: each Tab steps one further back, ⇧Tab steps forward, releasing ⌃
  opens the highlighted pane, and Esc cancels. The list stays in the same order
  while you choose and covers every device, whatever the device filter is set
  to (as ⌘K does). Each entry shows its name, status, space and device, and
  can be clicked. Panes on a disconnected device stay in the list, dimmed. The
  order is remembered across launches.

## [0.6.21] - 2026-10-21

### Fixed
- **New terminals and agents keep the chosen remote space.** Opening either
  sheet from a remote space's menu or the current selection no longer resets
  the space while initializing the device picker. Manually changing devices
  still resets the space for the newly chosen device.
- **SSH agent choices reflect installed CLIs.** New Agent checks the remote
  login-shell PATH instead of listing every supported manifest. Failed checks
  show the existing retry action; local binary overrides remain local.

## [0.6.20] - 2026-10-21

### Changed
- **New app icon.** A sidebar and a terminal pane on a blue gradient, deep at
  the top and lighter toward the bottom. The iOS app now ships the same icon;
  it had none before.

## [0.6.19] - 2026-10-21

### Added
- **Real thumbnails inside Claude's `[Image #N]` boxes.** Images you paste or
  drop into a Claude pane now show as pictures in the bordered box above the
  prompt, on Local and SSH devices alike. HerdrM draws them itself from the
  image it delivered, so the preview no longer depends on Claude detecting a
  picture-capable terminal. When HerdrM cannot tell which image a box belongs
  to, it draws nothing rather than guessing.
- **Add a Claude account from the Claude Accounts window.** "Add Account…"
  offers grazr's two ways to enrol without a terminal menu: save the login
  this machine uses now, or log in to another account, which opens a terminal
  on the device for Claude's sign-in and leaves the current login untouched.
  The name can be listed in ACCOUNTS at the same time, so grazr rotates to it;
  grazr's refusals, such as a name already in use, show in the form.
- **Project panel.** Each space has a Project view in the right pane, opened
  from the Project toggle in the pane titlebar or "Project…" in the agent,
  terminal and space row menus. It probes the space's device and lists the
  project's hot-reload servers with their ports, bind addresses, systemd units
  and log files. Docker Compose
  projects and containers show health and published ports, alongside the
  host's load, memory and Docker version. Local Parallels, VMPal and Lima VMs
  can be attached, declared or suggested for the project. Its URLs can be
  opened or copied, or overridden with the public address actually used.
  Overrides, attached containers and VMs, hidden listeners, remembered linked
  hosts and a custom project root persist per project in HerdrM's own store.
  The view is a config page of cards: an architecture overview shows the Mac,
  the host and its hot-reload, Docker and VM lanes with their linked hosts,
  followed by one card per section. Containers appear as tiles that reveal a
  detail strip when selected, and the layout holds up in narrow panes.
  Status refreshes every 15 seconds while the panel is visible. The panel is read-only
  in this release; start, stop and logs come next.
- **Select and transfer several files at once.** Use Command-click, Shift-click
  or Select All in either Files pane, then upload or download the selection
  in order. Choose one policy for existing files, see queue progress and a
  completion summary, or cancel the remaining transfers. A failed file is
  reported without preventing later files from being copied.
- **See how full a host is before starting an agent there.** The machine-stats
  panel shows a Linux host's room for another agent: free memory, swap, load
  per CPU, and how close herdr's panes are to herdr's own memory cap. When a
  host is critically full, New Agent asks before starting there; Start Anyway
  always proceeds, and a host that can't be read (macOS, offline, slow) never
  blocks a start. The memory lines scale with the host's RAM, so a small VPS
  isn't flagged just for being small.
- **Sort files by name, size or modification time.** Click a column heading
  in either Files pane to sort it; click again to reverse the direction.
  Folders stay first, and each pane keeps its own order when refreshing or
  changing folders. The active heading shows an arrow and announces its
  direction to VoiceOver.

## [0.6.18] - 2026-10-17

### Added
- **New Agent and New Terminal from a space's menu.** Right-click a space in
  the sidebar to start an agent or a terminal in it, without selecting it
  first.
- **Claude conversation history, read by HerdrM itself.** A thin prompt rail
  floats over the terminal edge, blurred when idle and clear on hover, with a
  prompt/reply preview per mark. Clicking a mark scrolls the agent's terminal to
  that prompt; an arrow returns to live output. The bubble on each Claude agent's
  sidebar card, or ⇧⌘H, opens the full conversation: Claude's replies, search,
  older/newer paging, collapsed tool activity, and reading or copying a complete
  message. Works with official herdr 0.9 and later; nothing on the server
  changes. HerdrM reads the transcript Claude Code already writes
  (`~/.claude/projects/…/<session>.jsonl`) on the device running the agent: a
  local file for Local, one SSH stream per open conversation for SSH devices,
  and nothing over Tailcat. The jump uses herdr's own pane search and scroll to
  reach a prompt still in the pane's scrollback. Claude in fullscreen mode keeps
  its own history, so there HerdrM presses PageUp in the terminal until the prompt
  is on screen, and ⌃End when you return to live (only the newest of repeated
  prompts can be found this way). A prompt the terminal cannot show opens in the
  reader instead.

### Fixed
- A request no longer fails with "setsockopt(SO_RCVTIMEO): Invalid argument"
  when herdr answers and closes the connection before herdrm reads the
  answer; the answer is read instead.
- **Section buttons and space counts are readable.** The New Space / New
  Agent / New Terminal buttons on the section headers now use the header
  title's color, and each space's agent count uses the space name's color.
  Both were drawn in the faintest gray and often could not be seen at all.
- **The sidebar no longer shows what is behind the window.** It used to blur
  the desktop or window behind HerdrM, so a bright window there washed the
  dark sidebar out to a mid gray and its labels, counts and header buttons
  faded. It is now the system's solid sidebar color in both light and dark.
- The chevron on a space row folds that space's panes when the sidebar is
  grouped by space. Clicking it used to select the space instead.
- VoiceOver reads the space chevron as Collapse / Expand space, and the
  sidebar's icon buttons by what they do: Group Sidebar by Space, Hide
  Sidebar, Settings. They were read by the space's name or by their icons'
  names, such as "Gear Shape". A new test fails when any sidebar control has
  no name or is read by its icon's name.

## [0.6.17] - 2026-10-13

### Changed
- **⌘D splits the herdr pane.** ⌘D and ⇧⌘D now add a herdr pane to the right
  of or below the selected one, as they would in the herdr TUI: the new shell
  opens in the selected pane's directory, joins the tab layout, shows in the
  sidebar under its pane, and the pane keys reach it. Until now ⌘D opened
  herdrm's own local shell beside the terminal area, which was in no tab, in no
  sidebar row, stayed on screen whichever pane was selected, and could only be
  reached with the ⌥⌘ arrows. That local shell is still there as Terminal ›
  Split with Local Shell Right / Down (⌃⇧D / ⌃⇧S), the keys the herdr splits
  had in 0.6.14.

### Added
- **⌘-click a file path to open it.** Paths printed in a pane open the way
  URLs do: `README.md` and `src/index.ts:42:7` resolve against the pane's
  working directory as herdr reports it, `~/notes.txt` and absolute paths as
  written, `file://` links too. Files open in their default app, folders in
  Finder; anything that would run (an app, a package, an executable) is
  revealed in Finder instead. Only paths that exist on this Mac become links,
  so "see README.md" in prose stays text and panes on remote devices are left
  alone. Hovering shows the same Copy button as for URLs.
- **Split panes nest in the sidebar.** A pane split off another lists indented
  under its tab's main pane (the oldest pane of the tab) with a split-pane
  glyph, in the main pane's section: a shell split off an agent sits under
  that agent in Agents. Once a tab is split, each pane shows its own title
  instead of the tab label, so a `cd` or herdr's auto-title renaming the tab
  no longer renames every pane of it.
- **Group the sidebar by space.** Off by default. Each space row gets a
  disclosure and lists its panes under it, a tab's main pane then the panes
  split off it, so a team of agents reads as one unit. Agents and Terminals
  stay as sections and collapse while grouping is on. Toggle from the sidebar
  strip, View › Group Sidebar by Space, or Settings › Appearance.

### Fixed
- Links work again: hovering a URL shows the Copy button and ⌘-click opens it.
  herdr's attach client keeps mouse reporting on, so herdrm maps the pointer to
  a cell itself, and the cell size it read from the session viewport was always
  0 with the current libghostty (the PTY resize callback does not carry it).
  The cell size now comes from Ghostty's grid resize delegate, with a fallback
  derived from the surface size.

## [0.6.16] - 2026-10-13

### Added
- **Name new agents after their project.** A new agent's default name now comes
  from its space / project folder instead of a generic label, and New Agent
  shows a **Recent** list of recent launches — one click starts the same kind of
  agent in the same folder again. The list is also seeded from the agents already
  running. (#129, thanks @senadaruc!)
- **Switch model automatically when Fable runs low.** When grazr is managing
  Claude and Fable's allowance runs out with usage credits off, herdrm answers
  Claude's "switch model and continue" prompt for you — matched by the dialog's
  whole shape, so it never confirms the wrong option — and the agent keeps
  working on the fallback model instead of stalling. A toggle in the Claude
  Accounts window turns it off. (#128, thanks @senadaruc!)
- **MCP servers in the machine stats.** The machine-stats details panel now
  lists each MCP server running on the host with its own CPU and RAM, so a
  runaway server process is easy to spot. (#131, thanks @senadaruc!)
- **Scroll an agent pane's history with the wheel.** Scrolling up in an attached
  agent pane now walks herdr's pane scrollback (`pane.scroll`), the way herdr's
  own client does, instead of sending the wheel to the agent's prompt. A "Jump
  to bottom" pill returns to the live end, and any input — typing, Return, a
  paste or a drop — snaps back there too. (#130, thanks @senadaruc!)
- **Hide the machine stats.** View › Show Machine Stats turns the CPU / RAM /
  DISK meters in the sidebar footer off and on. While they are hidden their
  sampler stops too, so a remote host no longer runs the stats loop over ssh.
  (#132, thanks @jt-wang!)

## [0.6.15] - 2026-10-10

### Added
- **Find in terminal (⌘F).** Opens a find bar over the focused pane that
  searches the pane's output and highlights matches. Return / ⇧Return (or
  ⌘G / ⇧⌘G) step down / up through matches, Esc closes it and returns to the
  terminal.
- **Pin an agent to a Claude account of its own.** grazr rotates one shared
  Claude login, so every agent used to run on the same subscription. Each Claude
  agent now gets one choice — Shared Rotation, or an account of its own (Agent
  menu › grazr › This Agent's Account, and an Account picker in New Agent). A
  pinned pane runs Claude on that account's own long-lived token, the rotation
  leaves it alone, and its usage is recorded under the account it actually runs
  on. The pin survives a herdr restart and `claude --resume`. Signing in an
  account that pinned agents need opens grazr's `claude setup-token` in a
  terminal on the device and pins the pane in the same step — the token never
  passes through herdrm. The Accounts window shows which agents are pinned to
  each account (with Renew… once a sign-in has under 30 days left), and a pinned
  account's line carries a pin glyph in the sidebar. Pinned accounts leave the
  rotation dial, clock and legend, as grazr does. (#127, thanks @senadaruc!)

## [0.6.14] - 2026-10-08

### Added
- **Split tabs show every pane.** When the selected pane's herdr tab is split,
  herdrm now lays out all of its panes the way the herdr TUI does, each one a
  live attach sized to its share of the window, instead of showing one pane at a
  time. Dividers drag the real herdr split ratio (`layout.set_split_ratio`), the
  layout follows `layout.updated` and pane open/close events, and clicking into a
  pane moves the selection (sidebar row, unread mark) there. A thin accent ring
  marks the selected pane. Zoomed tabs and single-pane tabs look as before. Teams
  of coding agents spawned side by side (pi-team-panes, Claude Code teammates)
  are readable in one view. Settings › Terminal › "Show every pane of the
  selected tab" turns it off, as does Terminal › Show Tab Panes (⇧⌘L).
- **Keyboard control of herdr panes.** The Terminal menu gains herdr's own
  splits, Split Pane Right (⌃⇧D) and Split Pane Down (⌃⇧S), which open a shell
  in the selected pane's directory and move the keyboard into it; Next Pane and
  Previous Pane (⌃⇧→ / ⌃⇧←) cycle through the tab in reading order; the ⌥⌘
  arrows that move focus inside the ⌘D split move between herdr panes when that
  split is closed; Zoom Pane (⇧⌘Z) is herdr's `pane.zoom`, so the TUI zooms the
  same pane; Close Pane… (⇧⌘W) is the sidebar's confirmed close for the pane
  that has the keyboard, with the selection moving on to the next pane of the
  tab. (#123, thanks @dulvac!)
- **Each account's Claude plan in the Accounts sheet.** A badge next to every
  email shows the subscription — Pro, Max 5x, Max 20x, Team 5x, … — read from
  the plan fields grazr already stores. The active account prefers Claude's own
  live profile (so a plan changed since enrolment still shows), parked accounts
  use grazr's copy, and older enrolments without the fields show no badge. No
  credentials are read. (#125, thanks @senadaruc!)

### Fixed
- Return confirms the Close agent/terminal dialog. The destructive button had no
  default-action binding, so Return (and Tab, Return) did nothing and the dialog
  could only be dismissed with the pointer. Escape still cancels. (#123)

## [0.6.13] - 2026-10-07

### Changed
- **Machine stats moved to the sidebar.** The CPU / RAM / Disk meters now sit in
  the bottom-left, just above the device switcher, instead of in a strip under
  the terminal — so they read as part of the device footer and the terminal
  keeps its full height. Clicking them opens the same details panel, now from
  the bottom-left.

## [0.6.12] - 2026-10-07

### Added
- **Live machine stats.** A strip under the terminal shows small CPU, RAM and
  Disk meters at its right end, lined up with the sidebar's device footer. They
  show how the host behind the selected pane is doing, Local or remote, and
  turn amber at 75% and red at 90%. Click them for a panel with:
  - load, uptime, a two-minute CPU history, and swap and per-disk usage
  - the CPU and memory used by herdr, by each agent kind (Claude, Codex,
    Gemini, …), and by each agent, named as in the sidebar
  - the heaviest other processes

  An agent's child processes (MCP servers, shells, builds) count toward that
  agent. Each device needs just one long-lived ssh session, which closes when
  you switch away or the window is hidden. (#111, thanks @senadaruc!)
- **Custom launch arguments per agent.** Settings → Agents has an arguments
  field for every agent (`droid --auto high`, `agy '--dangerously-skip-permissions'`,
  `--model …`), parsed shell-style, and the New Agent sheet starts from those
  defaults so you can tweak a single launch. A global **YOLO mode** switch
  pre-fills each agent's permission-bypass flag into its arguments, and turning
  it off strips just those flags. YOLO flags now also cover Droid, Antigravity,
  Kimi, Devin, Cline, Hermes, Kiro, Amp, Qoder, Qwen Code and Muse.
  (#117, thanks @thedavidweng!)
- **Switch Claude to the grazr account you pick.** An agent's grazr menu has a
  Switch to Account list (the active account ticked, a blocked one greyed out
  with its reason), and each card in the Accounts window has a Switch button.
  grazr's own swap only goes to the next account with headroom; this runs that
  same swap, with its lock, pane tags and log, pinned to the chosen account.
  (#116, thanks @senadaruc!)
- **Re-authenticate a grazr account** whose login stopped working (Blocked:
  authentication_failed), from its card or the agent's grazr menu. A terminal
  opens on the device and runs grazr's own enrol for that account
  (`claude auth login` in an isolated config dir, so the account Claude is on
  stays put); grazr keeps the new login and lifts the block. Signing in as a
  different account changes nothing. (#116, thanks @senadaruc!)
- **grazr rotation dial and clock** in the Accounts window. The dial shows the
  rotation as a clock face — one slice per account in rotation order, filled by
  what each has left this week or in the 5-hour window, a hand at the active
  account's usage, a tick at grazr's swap threshold, and the next account
  marked; per-model inner rings (e.g. Fable) and a red hand-off when nothing
  has headroom. The clock shows the rotation over time (24-hour or weekly face)
  coloured by the account grazr is expected to be on, with swap ticks and
  refill markers. The List | Dial choice is remembered. (#116, thanks @senadaruc!)
- The Accounts window's **Refresh** asks Claude for every account's usage
  through grazr (`grazr.py refresh`, grazr 0.4.7+senad.2 or later) before
  reloading, so an account that had refilled or had its limit lifted no longer
  keeps showing as spent. (#116, thanks @senadaruc!)
- Agent and terminal panes tell herdr that HerdrM's terminal draws Kitty
  graphics (`HERDR_ATTACH_GRAPHICS=1` on the attach command, set on the far
  side for remote devices). With a herdr that sends pane images to attach
  clients, pictures an agent shows — such as Claude Code's pasted-image
  thumbnails — appear in HerdrM, including on SSH devices. herdr versions
  without that support ignore the variable. (#115, thanks @senadaruc!)

### Changed
- The New Agent sheet's "Bypass permissions" switch became **YOLO mode**, which
  edits the visible arguments instead of silently appending a flag. The old
  default carries over. (#117, thanks @thedavidweng!)

### Fixed
- New Agent works on a device that has no Space left. herdr closes a Space
  together with its last pane, so closing the last terminal could leave a
  device with none, and New Agent then failed with "workspace_not_found: no
  active workspace". It now creates a Space (in your home folder on this Mac)
  and starts the agent there, and the sheet says so beforehand. Closing the
  last pane of a Space now also warns that herdr closes the Space too.
  (#114, thanks @senadaruc!)
- Editing a tailcat device now shows its tailcat token, not an empty SSH target
  field; a name-only save no longer reconnects, and saving can no longer turn a
  tailcat device into an SSH device and orphan its token. (#112, thanks @stu43005!)
- Tailcat devices no longer offer operations their tunnel can't do: New Terminal
  hides Standalone, New Space hides the folder browser (full paths like `C:\…`
  still work for Windows hosts), and the Files transfer picker leaves them out.
  Each only showed an error before. (#113, thanks @stu43005!)
- A remote device no longer fails to connect with "SSH tunnel failed: ssh exited
  0" when your ssh config shares connections (`ControlMaster auto`). If another
  ssh to the same host was already running (Mutagen, a terminal, another app),
  the tunnel was handed to that connection and herdrm's own ssh exited at once.
  The tunnel now always opens its own connection. (#119, thanks @senadaruc!)
- Remote devices no longer leave `ssh` tunnels running after herdrm is gone.
  Quitting already closed them, but stopping the app with `kill`/`pkill` skipped
  that step, and a crash or force quit left each tunnel up with its own
  connection to the host. herdrm now treats `kill` as a normal quit, and at
  launch it stops tunnels left behind by an earlier run and removes their
  sockets. (#120, thanks @senadaruc!)

## [0.6.11] - 2026-10-03

### Added
- The Agents and Terminals headers in the sidebar now have a small New Agent /
  New Terminal button at their right end, like the one by Spaces. You can start
  an agent or a terminal from the list you are working in, without moving the
  pointer and your attention up to the rows at the top of the sidebar.
  (#109, thanks @jt-wang!)
- **Persistent tailcat client key.** herdrm now keeps one tailcat client key per
  install (generated on first use, stored in the Keychain as this-device-only),
  so a host that allowlists clients can admit this Mac with a single `allow.list`
  line. The Add Device › Tailcat sheet and a new Settings › Tailcat tab show the
  client public key with a Copy button and the allow-list steps, and can
  regenerate the key behind a confirmation. Previously every session used a fresh
  ephemeral key, so an allowlisted host could never admit herdrm. (#110, closes
  #100, thanks @stu43005!)

### Fixed
- VoiceOver reads the sidebar's header buttons as New Space, New Agent and New
  Terminal. The New Space button was announced by its icon's name, "New Folder".
  (#109, thanks @jt-wang!)

## [0.6.10] - 2026-10-03

### Added
- The sidebar can be resized: drag the line between the sidebar and the
  terminal (200–480 pt), double-click it to go back to the default 260 pt. The
  width is remembered across launches, so long Space and Agent names fit.
  (#101, thanks @jt-wang!)
- **Copy on select.** Text selected with the mouse is copied to the clipboard on
  release, matching herdr's `copy_on_select`. A new toggle in Settings ›
  Terminal turns it off. (#99, thanks @senadaruc!)
- **Text drops.** Text dragged from an editor or a browser onto a pane pastes
  as text. Previously the pane only accepted files. Dropped file paths now end
  with a space, the way cmux does, so the prompt continues straight after them
  (local drops and remote uploads; clipboard path pastes stay verbatim).
  (#99, thanks @senadaruc!)
- **Copy a long link in one piece.** Resting the pointer on a link in a
  terminal shows a small Copy button above it; clicking it copies the whole
  link with no line breaks. herdr redraws its pane row by row, so a link that
  wraps reaches the terminal as separate lines, and selecting it copied a
  break at every row edge — login and OAuth URLs then failed with errors like
  "Unknown scope". The button rejoins the full-width rows the way ⌘-click
  already did, and copies the link exactly as printed. (#105, thanks @senadaruc!)
- **herdr plugin actions on right-click.** An agent's context menu lists every
  herdr plugin action on its device, one submenu per plugin, so grazr's account
  swap runs from the sidebar. Herdr's prefix keys never reach an attached pane,
  so this used to need a terminal on the device. The command's last line comes
  back as a notification, or as an alert when it failed. (#106, thanks
  @senadaruc!)
- **grazr accounts.** grazr › Accounts… lists every Claude account grazr
  rotates through on that device, with what each has left in its 5-hour,
  weekly and per-model windows and when they reset. The window also marks the
  active account, accounts the server refused, and accounts missing from
  `ACCOUNTS`, and swaps to the next account from a button. (#106, thanks
  @senadaruc!)
- The terminal now reports the cursor position to macOS accessibility clients
  (inline autocomplete overlays, dictation), so tools that work at the insertion
  point can read the prompt line being typed and draw beside the caret. (#108,
  thanks @senadaruc!)

### Fixed
- **Drag to select, click to expand.** In a pane whose app asks for the mouse
  (fullscreen Claude Code, or herdr's own attach client), a drag now selects
  text in the terminal without Shift, while a plain click still reaches the
  app, so Claude's collapsed messages and shell commands open by mouse. Double
  and triple click select a word or line. Previously the Mouse reporting
  setting had to choose between the two. (#104, thanks @senadaruc!)
- **Drops land in the agent you are looking at.** With several agents open,
  a file dropped on one agent was typed into another: every kept-alive
  terminal stayed registered for drops while hidden, and macOS gave the drop
  to the topmost one. Only the visible terminal accepts drops now. (#99, thanks
  @senadaruc!)
- **Sidebar stats lines no longer freeze on a pane herdr thinks is scrolled
  up.** Statusline plugins (herdr-agent-quota, grazr-style token scripts)
  skip every metadata update while herdr's server-side viewport for a pane is
  above the bottom — a viewport HerdrM never shows or scrolls, since ghostty
  owns the scrollback. Selecting a pane now snaps that viewport to the bottom,
  so the model, context and usage lines keep updating. (#99, thanks @senadaruc!)
- Image and file pastes now read the agent's kind from the live agent list, so
  an agent that was attached before herdr detected its kind — or restarted in
  the same pane — gets the right paste policy instead of a stale one. (#102,
  thanks @briandw!)
- The SSH tunnel's stderr handler no longer spins a CPU core after `ssh` exits:
  an EOF-readable handle was looping on empty reads until the tunnel was next
  rebuilt. (#103, thanks @senadaruc!)

## [0.6.9] - 2026-09-23

### Added
- Agent rows in the sidebar now show the stats that Herdr plugins publish as
  pane tokens, one line each under the agent/space line: the active account
  (grazr's `$grazr`), the model, context/cache, and 5h/7d usage. grazr's own
  `claude_*` tokens are preferred; herdr-agent-quota's `quota_*` tokens are the
  fallback, so a host running either plugin gets the same block the Herdr TUI
  shows. Rows without tokens are unchanged. (#96, thanks @senadaruc!)

### Fixed
- Terminals you are not looking at no longer render. Since kept-alive
  attaches (0.6.2), every agent you had opened stayed on screen at zero
  opacity and kept drawing full-window Metal frames whenever its output
  changed, so busy agents in other workspaces — worst over SSH and in large
  windows — made typing in the visible one lag. Hidden attaches, deselected
  shells, and terminals behind the file manager now tell Ghostty they are
  occluded: output is still parsed, only drawing pauses, and a pane is
  current the moment it is shown again. (#95)

## [0.6.8] - 2026-09-22

### Added
- Drag files or folders from Finder onto a terminal to hand them to the
  program: on this Mac the local paths are typed in; on an SSH device they are
  uploaded into the remote attachment cache first and the remote paths are
  typed in. Pasting copied folders (⌘V) now works on remote devices too —
  folders travel as one tar stream, capped at 200 MB and 20,000 items.

### Fixed
- ⌘-clicking a link while an agent captures the mouse (Claude Code's
  fullscreen mode) now opens it on this Mac. The click used to reach the
  agent, which opened the link itself — on a remote device, in the remote
  machine's browser.
- Dictation apps such as Typeless no longer leave their "copy this text" panel
  up after inserting into the terminal: the terminal now exposes itself to
  accessibility as a text area (visible text, selection), as Terminal and
  Ghostty do.

## [0.6.7] - 2026-09-20

### Added
- **Settings → Terminal → Import from Ghostty…** copies your `font-family` and
  `font-size` from `~/.config/ghostty/config` (honoring `XDG_CONFIG_HOME`) into
  herdrm's terminal settings, so switching over doesn't mean a jarring font
  change. It's a one-time import — herdrm's own settings stay in charge
  afterward — and it reports what it applied or skipped. (#73)

### Changed
- Changing language in Settings → Appearance now shows a **Relaunch** button
  that quits and reopens herdrm for you, instead of a hint to do it by hand.
  The button only appears when the UI language would actually change — English
  → Follow System is a no-op when the Mac is already English. (#94, thanks
  @thedavidweng!)

### Fixed
- ⌘-clicking a URL in the terminal now opens it. HerdrM never adopted
  libghostty's open-URL delegate, so clicks on OSC 8 hyperlinks and regex-matched
  links did nothing; both terminal coordinators now open `http`/`https`/`mailto`
  links through `NSWorkspace`. (#91, thanks @briandw!)
- SSH devices on Windows no longer fail the home probe (`echo "$HOME"` under CMD)
  or OpenSSH `-L` socket forwards (drive-letter paths). HerdrM detects Windows,
  proxies RPC through `herdr remote-api-bridge` over SSH stdio (same channel as
  the official CLI), and attaches panes via the local herdr CLI pointed at that
  bridge socket. (#92, thanks @thedavidweng!)
- The Notifications settings caption now wraps inside the fixed-width window
  instead of ending in an ellipsis. (#94, thanks @thedavidweng!)

## [0.6.6] - 2026-09-16

### Added
- Sidebar section headers (Spaces / Agents / Terminals) now stick to the top as
  you scroll — each header pins while its rows scroll under it and the next
  header slides over it with a fade, so you always know which section you're in.
  Collapse / expand still works while pinned. (#90, thanks @jt-wang!)

### Fixed
- macOS no longer attributes the coding agents' file-access prompts to herdrm.
  The on-demand `herdr server` (and the one-time login-shell PATH probe) are now
  spawned with their TCC responsibility disclaimed, so "'herdrm' would like to
  access data from other apps" prompts triggered by an *agent* reading a file are
  attributed to that process, not to herdrm — the same disclaim every terminal
  emulator applies to the programs it launches. Clicking **Don't Allow** was
  always safe; now the prompt stops naming herdrm for work herdrm didn't do.
  (#87)

## [0.6.5] - 2026-09-13

### Added
- New Space is now a top-level sidebar action alongside New Agent and New
  Terminal, so creating a space no longer means hunting for the small button
  by the Spaces header (which stays as a secondary affordance). (#84)

## [0.6.4] - 2026-09-13

### Added
- herdr named sessions (`herdr --session <name>` / `HERDR_SESSION`) now appear
  as extra Local devices in the switcher, instead of being invisible. Each live
  session under `~/.config/herdr/sessions/<name>/herdr.sock` is discovered at
  launch and on Reconnect; RPC, events, and terminal attach all target that
  session's socket. (#81, thanks @acy103!)
- The custom titlebar now behaves like a native macOS titlebar: drag it to
  move the window, and double-click it to follow the system Zoom, Minimize,
  or Do Nothing preference.

### Fixed
- Copy now works through both terminal paths: Command-C writes a local Ghostty
  selection directly to the macOS pasteboard, while agent TUI copy actions can
  write through OSC 52.
- HerdrSSH handshake compiles under Swift 6 region isolation: `performHandshake`
  no longer captures a local `OpaquePointer` across `repeatUntilComplete`
  awaits, so `HerdrMobile` / `make mobile-build` succeed again. (#85, thanks
  @jt-wang!)

### Changed
- Documented `make mobile-build` and `make ssh-test` (HerdrSSH Swift Testing on
  Simulator). Removed the HerdrSSH README “Direct-streamlocal / Jump Host
  acceptance” block that documented Heeler’s `scripts/run-ci-ios-tests.sh`
  workflow: that script and those suites were never checked into herdrm, so the
  old text told people to run something that does not exist here. (#85, thanks
  @jt-wang!)

## [0.6.3] - 2026-09-10

### Fixed
- Terminal text — most visibly CJK — no longer renders pale/faint. The
  keep-alive rework wrapped every attached terminal in `.opacity`, which
  forces SwiftUI to composite it offscreen; there, glyph anti-aliasing on
  Ghostty's non-opaque (clear) Metal layer fell back to a transparent
  backdrop and came out thin and gray, worst on dense Chinese strokes. A
  solid terminal-background backdrop inside the compositing group restores
  full-contrast text, matching the pre-keep-alive rendering.

## [0.6.2] - 2026-09-10

### Changed
- Switching between agents (and herdr terminals) now preserves each one's live
  terminal instead of re-attaching it. Every pane you open stays mounted and
  hidden, so switching back is instant and its scrollback and running state
  survive the round trip — no takeover churn, no redraw. A pane's kept-alive
  view is dropped when its pane actually closes. (thanks @lbr77 for the
  reference implementation!)

### Fixed
- Agent working / blocked / done indicators now update from herdr 0.9's
  pane-scoped `pane.agent_status_changed` events instead of waiting for an
  unrelated `pane.updated` event. Event names from both lifecycle and scoped
  envelopes are normalized, subscriptions follow newly created/moved panes,
  and continuous event bursts can no longer postpone snapshot refresh forever.
- Mouse gestures in attached agent TUIs now have one owner from press through
  release. Plain drags reach mouse-aware TUIs in full, while Shift-drag stays
  in Ghostty for local selection. Command-C copies a local Ghostty selection
  when present and otherwise reaches TUIs using the Kitty keyboard protocol,
  instead of a replayed press producing an oversized selection or leaving the
  TUI button logically held down. Herdr terminal panes follow the same rule:
  the wheel keeps scrolling herdr's own scrollback and Shift-drag selects
  locally, because `herdr … attach` has no server-side mouse selection — it
  forwards button events to the pane program and drops them when that program
  did not ask for the mouse.

## [0.6.1] - 2026-09-10

### Changed
- The embedded terminal now renders with libghostty (Metal) instead of
  SwiftTerm, on both the Mac app and the iOS/iPadOS client. Each pane is a
  host-managed Ghostty surface: on the Mac a local `forkpty` byte pump feeds
  it and carries keystrokes back to the PTY; on the phone the SSH PTY channel
  feeds it. herdrm keeps its own light-mode color adaptation, ⌘-editing-key
  readline chords, and agent-aware paste on top. Nerd Font glyphs, CJK, and
  the light/dark themes are preserved. (thanks @lbr77 for the reference
  implementation!)
- Tailcat devices now use an embedded WireGuard/DERP client (a gomobile
  build of tailcat, shared by macOS and iOS) instead of shelling out to the
  `tailcat` CLI. No `brew install tailcat`, and tailcat devices work on the
  iOS/iPadOS client too — where they carry herdr's control plane (spaces,
  agents, prompting) but not a live terminal, which stays SSH-only. On the
  Mac, terminal attach still rides the tunnel via the local herdr CLI. (the
  embedded bridge is also @lbr77's work!)

## [0.6.0] - 2026-09-10

### Added
- **Tailcat devices**: connect to a herdr behind NAT with no system VPN, no
  Tailscale account, and no port forwarding. On the remote Mac, the
  [herdr.tailcat](https://github.com/lbr77/herdr-plugin-tailcat) plugin
  exposes the herdr socket through a WireGuard/DERP tunnel; in herdrm,
  Add Device → Tailcat and paste the plugin's token (stored in the Keychain —
  it is a bearer credential). Terminal attach rides the same tunnel via the
  local herdr CLI (`HERDR_SOCKET_PATH`), so the CLI and remote server versions
  must match. Requires `brew install tailcat` locally. Each operation pays a
  tunnel handshake (~1–2 s); standalone shells and the Files workspace still
  need SSH. (#68, thanks @hualinli for pushing the userspace-tunnel idea!)
- Double-click a Space, Agent, or herdr Terminal in the sidebar to rename it
  (same sheet as the context menu). Terminals now rename via `tab.rename`, and
  a user-set tab label wins over the OSC title so the new name is visible.
  (#71, thanks @rosuH!)
- herdr Terminals in the sidebar can be drag-reordered. The drop calls the
  same `tab.move` path as Agents; cross-space drops are ignored. Standalone
  shells stay in creation order. Drag uses snapshot array order (the
  `insert_index` herdr actually applies), not tab `number`. Rows slide into
  place and the dragged row follows the pointer. (#72, thanks @rosuH!)

### Fixed
- The event subscription no longer drops every ~15 seconds on an idle
  session: the subscribe acknowledgement's read timeout stayed on the socket
  and killed the next blocking read, blinking the connection indicator
  through endless reconnects. Events that arrived in the same read as the
  acknowledgement are no longer discarded either. (#65, #66, thanks
  @hualinli!)
- After `tab.move`, a leftover numeric tab label (`"2"` on tab number 1)
  is no longer treated as a display name, so Agents keep their real title.
  (#72, thanks @rosuH!)
- Sidebar Space, Agent, and Terminal rows expose a VoiceOver default action
  so Activate selects the row (they are not SwiftUI `Button`s). (#71,
  thanks @rosuH!)
- Installed Oh My Pi (`omp`) now appears in the local New Agent picker even
  though its hook-based lifecycle integration has no screen-detection manifest.
  Settings → Agents also provides an Oh My Pi binary override. Install the
  lifecycle extension with `herdr integration install omp` before starting OMP.
  (#76, thanks @JackieJam!)
- New Agent no longer spins on "Checking agents…" forever when the device
  connection itself fails (herdr not installed, server not starting, protocol
  too old): the panel now shows the connection error with a Retry button
  instead of an endless spinner whose only hint was the footer indicator.
  (#69)

### Changed
- herdrm is now licensed under PolyForm Noncommercial 1.0.0 (#67): free to
  use, modify, and share for any noncommercial purpose; commercial use
  requires a separate license.

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

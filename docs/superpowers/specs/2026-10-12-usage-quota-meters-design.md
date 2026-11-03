# Usage Quota Meters — Design

- **Date:** 2026-10-12
- **Status:** Approved in brainstorming; pre-implementation
- **Branch:** `feat/usage-meters`
- **Inspiration:** Superset's Usage page (`superset-sh/superset`), adapted — not ported

## Summary

herdrm gains a **Usage** surface: quota meters per coding-agent provider
(Claude, Codex, Z.AI-via-OpenCode, Gemini), fetched through the CLIs' own
authenticated sessions and local data — herdrm never authenticates to any
provider API itself. A dedicated `UsageView` sheet shows meter cards grouped
by device; a compact sidebar-footer hint shows the tightest open window and
opens the sheet.

## Goals

- Fresh quota windows for Claude (and Codex where its local data carries them)
  without depending on statusline-plugin tokens.
- Coverage of OpenCode (Z.AI) and Gemini via their best available local
  surfaces, honestly framed (token statistics where no quota exists).
- Works on every device herdrm knows — local and SSH — via the existing
  device-side command pattern (`DeviceFileService.run`).
- **Fork-friendly:** additive-only changes; pulling from upstream
  (`missuo/herdrm`) stays conflict-light.

## Non-goals

- Token-usage history analytics / cost estimation charts (Superset's second
  pillar) — out of scope for this pass.
- Direct provider API calls with stored credentials (Superset's approach —
  explicitly rejected: the CLIs' sessions carry the auth).
- Resource meters — already covered by `MachineStats`.
- Changes to the herdr TUI/plugin protocol (would require upstream work).
- Background polling on a timer; refresh is user-driven (sheet open / ⌘R).

## Context — what exists today

- `Grazr.readerCommand` / `refreshCommand` (`Packages/HerdrKit/Sources/HerdrKit/GrazrAccounts.swift`):
  device-side Python that reads grazr's account snapshots; `refreshCommand`
  has grazr itself re-read every account from Claude. Run via
  `DeviceFileService(device:).run(...)` — works locally and over SSH.
- `GrazrWindow` (same file): quota window model — `kind`, `scope`, `group`
  (`session`/`weekly`), `remaining` percent, `resetsAt`. Reused as-is.
- `AgentStats.swift`: sidebar stats lines from plugin-published tokens
  (`quota_5h_warning` etc.) — the plugin-dependent path this feature
  complements.
- Sheet presentation pattern: `ContentView.swift:101`
  (`.sheet(item: $model.grazrAccountsDevice)`).

## Providers & data sources

| Provider | Mechanism (device-side) | Yields | Auth stance |
|---|---|---|---|
| Claude | grazr `refresh` + `reader` (existing commands) | True quota windows per account (5h / weekly / per-model) | grazr's own credentials, on-device |
| Codex | New Python snippet scanning `~/.codex/sessions` for the newest rate-limit record | Windows as Codex last reported (5h / weekly) | No auth — local files |
| OpenCode (Z.AI) | `opencode stats --json --days 7` (+ `opencode auth list`) | Token usage stats (input/output/reasoning/cache), sessions; **no quota windows** | CLI's own session |
| Gemini | New Python snippet aggregating `~/.gemini/tmp/*/usage.json` | Derived meter: tokens over recent sessions; no official quota file | No auth — local files |

## Architecture

### New files

**HerdrKit** (`Packages/HerdrKit/Sources/HerdrKit/`):

1. `AgentUsage.swift` — the model:
   - `enum UsageProvider: String, CaseIterable { claude, codex, opencode, gemini }`
   - `struct AgentUsageReading`: `provider`, `account: String?`,
     `windows: [GrazrWindow]` (Claude/Codex), `tokens: UsageTokens?`
     (OpenCode/Gemini), `fetchedAt: Date`.
   - `struct UsageTokens`: input, output, reasoning, cache read/write,
     period start/end.
2. `UsageSources.swift` — per-provider command builders (mirroring
   `Grazr.readerCommand`'s shape) + pure parsing functions from command
   stdout to `AgentUsageReading`. Claude's source composes the existing
   grazr commands; Codex/Gemini embed small Python heredocs; OpenCode
   invokes the `opencode` binary (located via the device PATH export, as
   other device commands do).
3. `UsageStore.swift` — `actor` holding per `device × provider` readings:
   5-minute TTL cache, single-flight in-flight task reuse, error eviction.

**App** (`Sources/HerdrM/`):

4. `UsageView.swift` — the sheet. Sections per device; meter cards per
   provider. Claude accounts render windows the way the Accounts sheet
   treats them (progress + reset time); OpenCode/Gemini render token
   statistics labeled as usage, not quota.
5. `UsageModel.swift` — `ObservableObject` driving loads, refresh, and
   published state per device.

### Existing-file edits (the only ones)

| File | Change |
|---|---|
| `AppModel.swift` | + one `@Published var usageDevice: Device?` (mirrors `grazrAccountsDevice`) |
| `ContentView.swift` | + one `.sheet(item: $model.usageDevice)` line beside the grazr one |
| `SidebarView.swift` | + footer hint line & button (tightest open window; opens sheet) |
| `Resources/Localizable.xcstrings` | + new keys (en, zh-Hans) |

`project.yml` globs `Sources/HerdrM` by directory and HerdrKit is a Swift
package, so new files require no build-manifest edits.

## Data flow & refresh

1. Footer button → `model.usageDevice = device` → sheet presents →
   `UsageModel.refresh(device)`.
2. Per provider: `UsageStore` returns cached reading if younger than 5 min;
   otherwise the store runs (or joins) the in-flight command.
3. Command executes via `DeviceFileService(device:).run` — local `Process`
   or SSH, 30 s timeout.
4. stdout JSON parses (pure functions) into `AgentUsageReading`; published;
   cards render.

**Claude cadence discipline:** grazr's `refresh` (per-account API reads on
the device) runs only on sheet open or ⌘R, gated by the store's TTL —
mirroring Superset's "never poll faster than 5 minutes" rule against
provider 429s. The cheap reader-only path may serve younger caches.

## UI

**UsageView sheet** — one section per connected device, in sidebar order.
Within a section, one card per provider, presence-ordered
(Claude → Codex → OpenCode → Gemini). Each card: provider identity + account
name, then either quota meters (one per window: label, progress bar of
`left(now:)`, reset time via `GrazrStyle.time`) or token statistics
(labeled "usage", never "quota"). Card footer shows reading age. ⌘R refreshes
the visible device; per-card state per *States & error handling*.

**Sidebar footer hint** — one line at the sidebar's foot showing the
*tightest open window*: the open window (across all providers and devices
with fresh readings) with the lowest `left(now:)`, rendered as
`<label> <n>% · <time left>` in the severity color the grazr windows use.
Tapping it opens the Usage sheet. Absent readings render nothing.

## States & error handling

Every provider card stands alone; one failure never blanks the sheet.

- **Reading** — windows/meters with age (`fetchedAt`).
- **Tokens-only** — OpenCode/Gemini: statistics labeled as such.
- **Not installed / signed out** — grazr absent, no `~/.codex`, no
  `opencode` on PATH: quiet empty-state card.
- **Stale** — device offline or timeout: last reading greyed with age.
- **Unknown** — Codex sessions present but no rate-limit records parsed:
  "Codex hasn't reported limits yet".

## Privacy & security

Only names, plan metadata, percentages and token counts leave a device.
Credentials never leave a device and never pass through herdrm. herdrm makes
no network calls itself; all provider contact happens inside the CLIs/grazr
on the device, under their own sessions.

## Testing

- **Parser fixtures** (`Tests/HerdrKitTests/Fixtures/Usage/`): committed
  samples of grazr report JSON, codex session records, gemini `usage.json`,
  opencode stats JSON → table-driven parser tests (`AgentStatsTests` style).
- **Command-builder tests**: generated snippets run against the local
  machine where the tool exists (pattern: `GrazrAccountsTests:340`);
  skip-marked otherwise.
- **Store tests**: TTL expiry, single-flight dedupe, error eviction.
- **UIUX test**: sheet states + footer hint, per `SidebarHarness`
  conventions.

## Risks & spikes

1. **Codex session format varies by version** — implementation step 1 is a
   throwaway probe against this machine's `~/.codex/sessions` to pin the
   rate-limit record shape. Parser stays defensive (`Unknown` state).
2. **Gemini `usage.json` presence** — the file is an implementation detail
   of the Gemini CLI and may vanish; the source degrades to "no data" if
   absent.
3. **`opencode stats` on remote devices** — may spin the background server
   on first run; the 30 s timeout bounds the cost, and the card degrades
   gracefully.
4. **grazr refresh heaviness** — serial per-account reads; acceptable
   because user-driven and TTL-gated.

## Fork strategy

- Branch `feat/usage-meters` off `main`; commit slices, each green:
  ① HerdrKit model + parsers + fixtures → ② sources/command builders →
  ③ store → ④ UsageView + UsageModel → ⑤ sidebar hint + wiring.
- All new files except four additive hunks (above). No refactors, no
  adjacent-line reformatting, no file moves.
- Upstream-merge surface = those four hunks; everything else lives at
  paths upstream does not have.

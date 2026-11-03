# Usage Round Two — Widget Realignment, Grazr-free Claude, History Charts — Design

- **Date:** 2026-10-13
- **Status:** Approved in brainstorming; pre-implementation
- **Branch:** `feat/usage-meters` (continues round one)
- **Precedes:** `2026-10-12-usage-quota-meters-design.md` (round one)

## Summary

Three changes to the usage feature: the sidebar hint becomes a **USAGE meter
column** inside the CPU/RAM/DISK row (with a sheet-side selector for which
model it watches); Claude's quota source switches from grazr to the Claude
CLI itself (`claude -p '/usage'` — the CLI is the only authenticated party);
and the Usage sheet gains **per-device usage-history charts** with daily
token bars and Superset-style approximate dollar estimates from local
transcripts.

## Goals

- The usage widget speaks the machine-stats widget's exact visual language.
- Claude quota without grazr: `claude -p '/usage'` parsed on-device; grazr
  is removed from the usage feature entirely (the upstream Accounts sheet
  keeps its own grazr usage — untouched).
- Usage history: stacked daily token bars per provider (7d/30d), per-model
  breakdown where data carries it, approximate $ totals from a dated price
  table.
- Same constraints as round one: additive-only fork discipline, no
  herdrm-side authentication anywhere, device-side commands via
  `DeviceFileService.run`, localization en + zh-Hans.

## Non-goals

- Cost precision beyond API-list-rate estimates (labeled approximate).
- Persistence of history (computed on demand, TTL-cached like quota).
- Gemini history (no local token data exists on target machines).
- Leaderboards, drilldown pages, or any other Superset surface.

## 1. Sidebar USAGE column

- `MachineStatsView.swift`'s `SidebarMachineStats` row gains a fourth
  `SidebarMeter` column labelled **USAGE**: percent **used** of the
  tightest open window for the watched model across all devices
  (`remaining` inverted so the existing `levelColor` semantics — ≥75
  warning, ≥90 danger — apply unchanged).
- The USAGE column is individually tappable and opens the Usage sheet; the
  rest of the row keeps opening `MachineStatsPanel`.
- No readings yet → the column renders dimmed ("—"), never vanishes (the
  `600ce7d` lesson: `.task` must anchor to a real view).
- `UsageHintLine` (round one's text row) is **removed**, superseded by the
  column; its refresh logic moves to the sidebar stats block level.
- **Watched-model selector** in the Usage sheet: a picker listing "All
  models" plus every distinct window scope found in current readings
  (e.g. Claude's "Fable" weekly window). Persisted via `@AppStorage`
  (`usage.sidebarWatchedModel`, String, empty = all models). Selection
  rule: tightest open window whose scope matches the selection (scope-nil
  windows always qualify); if the watched model yields no window, fall
  back to the all-models window so the meter never blanks.

## 2. Grazr-free Claude quota

- `UsageSources.swift` claude command becomes
  `SSHTunnel.remotePathExport + "claude -p '/usage'"` (works locally and
  over SSH wherever the CLI exists).
- Parser: read lines matching `Current <window>: <n>% used · resets <date>`
  from the spike-pinned output; windows map to `GrazrWindow` —
  `session` → group "session"; `week (all models)` → group "weekly",
  scope nil; `week (<Model>)` → group "weekly", scope `<Model>`;
  `remaining = 100 − used`; `resetsAt` parsed with an en-US-pinned
  `DateFormatter` ("Oct 13 at 3:09pm (Europe/Warsaw)"; year inferred as
  the calendar year of today, rolled over if the parsed date is > 11
  months in the past).
- Unrecognized output → `UsageParseResult(installed: true, readings: [])`
  → `.unknown`. Missing lines are skipped. Never a crash.
- `UsageStore`'s claude branch drops the grazr `refreshCommand`/`readerCommand`
  pair: plain TTL read; `force` re-runs `claude -p '/usage'` directly.
- The claude `.notInstalled` state means "claude CLI missing" — copy
  returns to plain "Not installed" (grazr copy retired).

## 3. Usage history

### New HerdrKit files

- **`UsageHistory.swift`** — `struct UsageDay: Identifiable, Equatable,
  Sendable { date: Date; tokens: [UsageProvider: UsageTokens] }`;
  `struct UsageHistory { days: [UsageDay]; generatedAt: Date }`.
- **`UsageHistorySources.swift`** — device-side aggregators (Python
  heredocs, `remotePathExport`-prefixed like round one):
  - **Claude**: walk `~/.claude/projects/**/*.jsonl`; consider only
    `type == "assistant"` records carrying `usage`; **dedupe on
    `message.id` + `requestId`** (Superset's anti-double-count rule); sum
    input/output/cache tokens per **local-timezone day**; record the
    message's model for the per-model split.
  - **Codex**: walk `~/.codex/sessions/**/*.jsonl`; per file take the
    **last** `token_count` event's `total_token_usage` (cumulative — never
    sum across events); bucket by the session's last-event day; model from
    the record.
  - **OpenCode**: `opencode stats --json --days 30`; consume its
    `activity` and `models` keys — exact shape pinned by an in-plan probe
    before the parser is written (fixture follows the probe).
  - Both heredocs **pre-filter files by mtime** (now − 30 days) before
    parsing, stream line-by-line, and print one JSON document:
    `{ "days": [{ "date": "YYYY-MM-DD", "tokens": {provider: {...}} }],
    "models": {provider: {model: tokens}} }`.
- **`UsagePricing.swift`** — dated per-model price table (per-1M input /
  output / cache-read / cache-write rates; cache multipliers), longest-
  prefix model match (`fable-5.1-sonnet` → `fable-5.1`), unknown model →
  cheapest known rate with `approximate = true`, `PRICING_TABLE_UPDATED`
  date constant. Cost: `Σ tokens/1M × rate` per model per day.

### App side

- `UsageModel`: `@Published histories: [UUID: UsageHistory]`;
  `refreshHistory(_ device:)` reuses `UsageStore` under keys
  `history:{device}` (same TTL + single-flight; 30-day range fixed).
- `UsageView`: per device section gains a **History block** — Swift Charts
  stacked `BarMark` daily tokens by provider (round-one Theme palette),
  7d default with a 7d/30d segmented toggle, totals row with the $ figure
  rendered "$X.XX (approx.)", per-model breakdown list where models are
  known. Empty history → "No history yet"; stale/offline → greyed with
  age; Gemini absent from charts by design. The sheet header also hosts
  the **watched-model picker** (§1).
- Sheet refresh (open + ⌘R) refreshes quota and history together.

## States & error handling

Per-card/per-block independence as round one: a provider failure never
blanks the sheet or the column. `.failed` remains thrown-errors-only.
Tailcat devices stay `.failed`. The USAGE column's dimmed state covers
"nothing read yet" and "all windows closed".

## Testing

- Kit fixtures: claude JSONL with duplicate ids (counted once), codex
  sessions with multiple token_count events (last wins), opencode
  activity JSON (per probe), `/usage` text (happy, missing-line,
  unrecognized), pricing (prefix match, multipliers, approximate
  fallback, dated constant), day bucketing pinned to a fixed timezone.
- UIUX: USAGE column render + tap routing (sheet, not MachineStatsPanel),
  dimmed state, watched-model selector + `@AppStorage` persistence +
  all-models fallback, history block (bars, toggle, approx label).
- The round-one production-wiring test re-anchors onto the column.

## Fork strategy

- New files: the three Kit files + their tests + UIUX test files.
- Editable freely (round-one files, unknown upstream): `UsageSources`,
  `UsageStore`, `UsageModel`, `UsageView`, hint-test files.
- Minimal hunks in upstream files: `MachineStatsView.swift` (USAGE
  column), `SidebarView.swift` (hint-removal + stats-block refresh
  anchor), `Resources/Localizable.xcstrings`, `CHANGELOG.md`.
- Cleanup rides the slices: round one's "Needs grazr" copy + tooltip key
  retire with the grazr source; `UsageHintLine` and its test file are
  deleted with the column commit.
- Commit slices: ① Claude source swap ② USAGE column + selector
  ③ history model + sources + fixtures ④ pricing ⑤ charts UI
  ⑥ cleanup + changelog.

## Risks

1. `/usage` output drift → defensive parser → `.unknown` (bounded).
2. OpenCode `activity` shape unknown until probe — parser follows the
   pinned fixture, `unknown` on mismatch.
3. Transcript volume — mtime pre-filter + streaming + 30 s timeout.
4. Local-day bucketing at month/year edges — pinned by timezone-fixed
   fixture tests.
5. `claude -p` runtime (seconds) — user-driven cadence + TTL only.

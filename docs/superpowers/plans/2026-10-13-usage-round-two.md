# Usage Round Two Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** USAGE as a 4th tappable sidebar meter column (watched-model aware), Claude quota via `claude -p '/usage'` (grazr removed), and per-device usage-history charts with approximate dollar estimates inside the Usage sheet.

**Architecture:** Continues round one's quota module in HerdrKit. New history module (`UsageHistory`/`UsageHistorySources`/`UsagePricing`) with device-side aggregators and client-side cost math; USAGE column reuses `SidebarMeter`; charts via Swift Charts in `UsageView`; all data flows through the existing `UsageStore` TTL/single-flight.

**Tech Stack:** Swift 5, SwiftUI + Swift Charts (system framework, macOS 14 — no new dependencies), XCTest, Python heredocs as device commands.

**Spec:** `docs/superpowers/specs/2026-10-13-usage-round-two-design.md` — read it first; the plan argues from it. One refinement over the spec: opencode's `activity` carries **steps per day only**, so opencode has **no daily token series** — it contributes per-model rows, range totals and $ only; daily bars are Claude + Codex.

## Global Constraints

- macOS 14.0 deployment target; **no new package dependencies** (Swift Charts is a system framework).
- herdrm performs zero provider network calls and reads no credential files; the only authenticated party for Claude is the Claude CLI itself (`claude -p '/usage'`).
- Device commands via `DeviceFileService(device:).run` (30 s default timeout), `SSHTunnel.remotePathExport`-prefixed.
- Every user-facing string via `String(localized:)`; keys in `Resources/Localizable.xcstrings` for **en** and **zh-Hans**, in key order.
- Dollar figures always render "$X.XX (approx.)" — never presented as money spent.
- Fork discipline: round-one files (`UsageSources/UsageStore/UsageModel/UsageView`, hint tests) are freely editable; upstream files (`MachineStatsView.swift`, `SidebarView.swift`) get minimal hunks only.
- Kit tests: `cd Packages/HerdrKit && swift test`; UIUX: `make uiux-test`; app gate: `make build`.
- Dedupe rules (binding): Claude history counts `type == "assistant"` records with `usage`, deduped on `message.id + requestId`; Codex history takes the **last** `token_count` event's `total_token_usage` per session file (cumulative — never summed across events).

## Review Focus

1. **`claude -p '/usage'` output drift / unrecognized text** → `.unknown`, never a decode crash — Task 1 (`testUnrecognizedUsageOutputYieldsUnknown`).
2. **Reset-date year rollover** ("resets Jan 3" parsed on Dec 31) → next year inferred, not 11 months in the past — Task 1 (`testResetDateRollesOverYearBoundary`).
3. **Claude duplicate message ids across session files** counted once — Task 3 (`testDuplicateMessageIdsAcrossFilesCountOnce`).
4. **Codex cumulative `total_token_usage` double-summed** across a session's many `token_count` events — Task 3 (`testCodexSessionTotalsNotDoubleSummed`).
5. **Watched model with no open window** → falls back to the all-models window; the column never blanks — Task 2 (`testWatchedModelFallsBackToAllModelsWindow`).

---

### Task 1: Claude quota via `claude -p '/usage'`

**Files:**
- Modify: `Packages/HerdrKit/Sources/HerdrKit/UsageSources.swift`, `Packages/HerdrKit/Sources/HerdrKit/UsageStore.swift`, `Packages/HerdrKit/Tests/HerdrKitTests/AgentUsageTests.swift`, `Sources/HerdrM/UsageModel.swift` (copy retirement)
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsageSourcesTests.swift`

**Interfaces:**
- Consumes: round-one `UsageSource.command(for:)`/`parse`, `UsageStore.reading(_:on:force:)`.
- Produces: `enum UsageSource { static let claudeUsageCommand: String; static func parseClaudeUsage(_ text: String, fetchedAt: Date) -> UsageParseResult? }` — same normalized schema as codex (`{installed, windows: [{used_percent, window_minutes, resets_at}], tokens: nil}`); other tasks unaffected.

- [x] **Step 1: Write failing tests** in `UsageSourcesTests.swift`:
  - `testClaudeUsageCommandWrapsCLI` — `UsageSource.claudeUsageCommand` starts with `SSHTunnel.remotePathExport`, contains `command -v claude` guard (missing CLI → prints `{"installed": false}`) and `claude -p /usage`.
  - `testClaudeUsageTextParsesWindows` — feed the spike output verbatim (three lines: `Current session: 15% used · resets Oct 13 at 3:09pm (Europe/Warsaw)`, `Current week (all models): 13% used · resets Oct 17 at 3:59pm (Europe/Warsaw)`, `Current week (Fable): 13% used · resets Oct 17 at 3:59pm (Europe/Warsaw)`); with `fetchedAt` fixed at 2026-10-13 assert: session window `group == "session"`, `remaining == 85`; weekly `scope == nil`, `remaining == 87`; model weekly `scope == "Fable"`; `resetsAt` == date parsed with en-US formatter.
  - `testUnrecognizedUsageOutputYieldsUnknown` — `"error: something"` → `UsageParseResult(installed: true, readings: [])`.
  - `testResetDateRollesOverYearBoundary` — `resets Jan 3 at 1:00pm` with `fetchedAt` 2026-12-31 → `resetsAt` in 2027.
  - Update `UsageStoreTests.testClaudeForceRunsRefreshThenReader` → `testClaudeForceRerunsSingleCommand`: claude now issues exactly `[claudeUsageCommand]` for both plain and force paths.
  - Update `AgentUsageTests` claude `.notInstalled` expectations: plain "Not installed" (drop the "Needs grazr" special case + its tooltip in `UsageModel.swift`/`UsageView.swift` and the two xcstrings keys retire in Task 7's sweep — safe to leave keys until then).

- [x] **Step 2: Run, verify fail** — `cd Packages/HerdrKit && swift test --filter UsageSourcesTests` → FAIL (no `claudeUsageCommand`).
- [x] **Step 3: Implement** — command: `remotePathExport + "if command -v claude >/dev/null 2>&1; then claude -p /usage; else echo '{\"installed\": false}'; fi"`. Parser: en-US `DateFormatter` pattern `"MMM d 'at' h:mma (zzz)"`, year = calendar year of `fetchedAt`, `+1 year` if parsed > 11 months before `fetchedAt`; line regex `^Current (session|week(?: \((.+)\))?): (\d+)% used`; `week (all models)` → scope nil. Store: claude branch returns the single command for both paths; delete the grazr compose.
- [x] **Step 4: Run, verify pass** — full `swift test --filter Usage` filters.
- [x] **Step 5: Commit** — `feat(usage): claude quota via claude -p /usage, grazr removed`.

### Task 2: USAGE column + watched-model selector

**Files:**
- Modify: `Sources/HerdrM/MachineStatsView.swift` (SidebarMeter + column), `Sources/HerdrM/SidebarView.swift` (wiring, hint removal), `Packages/HerdrKit/Sources/HerdrKit/AgentUsage.swift` (selection helper), `Sources/HerdrM/UsageView.swift` (picker), `Resources/Localizable.xcstrings`
- Delete: `Tests/HerdrMTests/UsageHintTests.swift` row-render cases (keep refire/selection semantics by moving them)
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/AgentUsageTests.swift`, `Tests/HerdrMTests/UsageColumnTests.swift` (new)

**Interfaces:**
- Consumes: `UsageModel.states`, `GrazrWindow`, round-one store refresh.
- Produces:
  - Kit (`AgentUsage.swift`): `enum UsageSelection { static func tightestWindow(states: [UUID: [UsageProvider: UsageProviderState]], devices: [Device], scope: String?, now: Date) -> (device: Device, window: GrazrWindow)? }` — only open windows; `scope == nil` matches scope-nil windows; non-nil scope matches that scope first, falling back to scope-nil when the model yields none.
  - App: `SidebarMeter` gains `var action: (() -> Void)? = nil` (rendered as a nested `Button` when set — inner tap wins over the row's `toggle`); `AppModel` gains `@AppStorage("usage.sidebarWatchedModel") var sidebarWatchedModel: String = ""`.
  - `SidebarMachineStats` gains `usagePercent: Double?` and `onUsageTap: () -> Void` parameters; SidebarView passes `100 − tightestWindow(...).window.left(now:)`.

- [ ] **Step 1: Write failing tests** — Kit: `testWatchedModelFallsBackToAllModelsWindow` (readings with only scope-nil weekly + a "Fable" scope on another device; scope "Fable" picks the Fable window; scope "Missing" falls back to scope-nil). UIUX (`UsageColumnTests`): stats row renders a "USAGE" meter column; tapping it sets `model.usageDevice` (NOT `model.showMachineStats`); with no readings the column shows "—" dimmed; watched-model picker in the sheet header lists "All models" + scopes from readings and persists to the AppStorage key.
- [ ] **Step 2: Run, verify fail** — `make uiux-test` filtered → FAIL.
- [ ] **Step 3: Implement** — per interfaces; move the hint's `.task(id:)` refresh anchor onto the stats block itself in `SidebarView` (anchored to a real view — the `600ce7d` lesson); delete the `UsageHintLine` struct and its standalone row; production test from round one re-anchors onto "USAGE".
- [ ] **Step 4: Run** — `make kit-test && make uiux-test && make build` → green.
- [ ] **Step 5: Commit** — `feat(usage): USAGE meter column with watched-model selector`.

### Task 3: History model + Claude/Codex aggregators

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/UsageHistory.swift`, `Packages/HerdrKit/Sources/HerdrKit/UsageHistorySources.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsageHistoryTests.swift`

**Interfaces:**
- Consumes: `UsageTokens`, `UsageProvider`, `DeviceFileService`.
- Produces:
  - `struct UsageDay: Identifiable, Equatable, Sendable { var date: Date; var tokens: [UsageProvider: UsageTokens]; public var id: Date { date } }`
  - `struct UsageHistory: Equatable, Sendable { var days: [UsageDay]; var modelTotals: [UsageProvider: [String: UsageTokens]]; var generatedAt: Date }`
  - `enum UsageHistorySource { static func command(for provider: UsageProvider) -> String?; static func parse(_ provider: UsageProvider, stdout: Data, fetchedAt: Date) -> UsageHistory? }` — `.gemini` → nil (no source).
  - Normalized emit schema: `{"days": [{"date": "YYYY-MM-DD", "input": N, "output": N, "reasoning": N, "cache_read": N, "cache_write": N}], "models": {"<model>": {"input": N, "output": N, "reasoning": N, "cache_read": N, "cache_write": N}}}` (dates in the device's local timezone).

- [ ] **Step 1: Write failing tests** (inline fixtures; local-tz pinned via fixed `TimeZone`):
  - `testClaudeAggregatorDedupesMessageIds` — temp HOME with two session files where the same `message.id + requestId` appears in both → counted once.
  - `testClaudeAggregatorSumsByLocalDay` — records on 2026-10-12 23:30 and 2026-10-13 00:30 in a fixed UTC+2 zone land on the 12th and 13th.
  - `testCodexSessionTotalsNotDoubleSummed` — one session file with three `token_count` events (growing `total_token_usage`) → the **last** totals counted once.
  - `testClaudeAggregatorSkipsNonAssistantAndUsageless` — user lines and assistant-without-usage skipped.
  - `testParseMapsNormalizedSchema` — decoder test with a hand-written normalized doc.
- [ ] **Step 2: Run, verify fail** — `swift test --filter UsageHistoryTests` → FAIL.
- [ ] **Step 3: Implement** — two heredocs (pattern: round one's codex command), both mtime-filtered (`now − 30d`) and streaming:
  - **claude**: walk `~/.claude/projects/**/*.jsonl`; for `type == "assistant"` with `message.usage`, dedupe `message.id + requestId`; accumulate `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens` per local day and per `message.model`.
  - **codex**: walk `~/.codex/sessions/**/*.jsonl`; per file track the last `payload.type == "token_count"` event; on EOF add its `total_token_usage` fields once, bucketed by that event's timestamp day, model from `payload.info.model` when present.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** — `feat(usage): history model and claude/codex transcript aggregators`.

### Task 4: OpenCode history source

**Files:**
- Modify: `Packages/HerdrKit/Sources/HerdrKit/UsageHistorySources.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsageHistoryTests.swift`

**Interfaces:**
- Consumes: Task 3's `parse`; live shape (pinned by probe 2026-10-13): `opencode stats --json --days 30` → `models: [{model: {id, providerID, variant}, steps, tokens: {input, output, reasoning, cache: {read, write}}, cost}]`; `activity` is steps-only and is **not used**.
- Produces: `UsageHistorySource.command(for: .opencode)` = remotePathExport + guarded `opencode stats --json --days 30`; parse maps `models[].model.id` → `modelTotals["opencode"]`, `days: []` (no daily series — spec refinement).

- [ ] **Step 1: Failing test** — `testOpencodeHistoryMapsModelTotalsOnly` — fixture from the live output (glm-5.3 default + high variants; assert `days.isEmpty`, two model entries, cache read 406_215_424).
- [ ] **Step 2: Verify fail.** **Step 3: Implement** (command guard pattern from Task 1; merge variant totals by bare `model.id`). **Step 4: Verify pass.**
- [ ] **Step 5: Commit** — `feat(usage): opencode per-model history totals`.

### Task 5: Pricing

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/UsagePricing.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsagePricingTests.swift`

**Interfaces:**
- Produces: `struct UsagePricing { static let tableUpdated = "2026-10-13"; static func cost(of tokens: UsageTokens, model: String) -> (dollars: Double, approximate: Bool) }` — per-1M rates, longest-prefix model match, unknown model → cheapest known rate + `approximate = true`.

- [ ] **Step 1: Failing tests** — prefix match (`claude-opus-5-5-20261001` → `claude-opus-5-5` rate), cache multipliers (cache read ≤ input rate × 0.1, cache write × 1.25 — asserted against the seeded table), unknown → cheapest + approximate, math exactness (`tokens/1e6 × rate`).
- [ ] **Step 2: Verify fail.** **Step 3: Implement** — seed the table with current list rates for the models in this repo's fixtures, sourced at implementation time from the official pages (anthropic.com/pricing, openai.com/api-pricing, z.ai pricing) with source comments; rates are data, structure is the interface. **Step 4: Verify pass.**
- [ ] **Step 5: Commit** — `feat(usage): dated pricing table with approximate fallback`.

### Task 6: History charts in the sheet

**Files:**
- Modify: `Sources/HerdrM/UsageView.swift`, `Sources/HerdrM/UsageModel.swift`, `Packages/HerdrKit/Sources/HerdrKit/UsageStore.swift` (history key namespace), `Resources/Localizable.xcstrings`
- Test: `Tests/HerdrMTests/UsageHistoryUITests.swift`

**Interfaces:**
- Consumes: Tasks 3–5 (`UsageHistory`, `UsageHistorySource`, `UsagePricing`).
- Produces: `UsageModel.histories: [UUID: UsageHistory]` + `refreshHistory(_ device: Device) async` (store key `"history:\(device.id)"`, 30-day range, TTL/single-flight inherited); `UsageHistoryBlock` (private, in UsageView) — stacked `BarMark` daily tokens (claude + codex), 7d/30d segmented toggle, totals row with `UsagePricing` dollars rendered "(approx.)", per-model rows for all three providers.

- [ ] **Step 1: Failing UIUX tests** — with preloaded `histories`: chart bars expose per-day totals via accessibility labels ("Oct 12 · 1.2M tokens" style), toggle switches 7↔30, totals row contains "$" and "approx.", per-model row lists model + tokens; empty history reads "No history yet"; stale shows age.
- [ ] **Step 2: Verify fail** — `make uiux-test` filtered.
- [ ] **Step 3: Implement** — Swift Charts (`import Charts`), Theme palette per provider (round-one colors), sheet refresh (open + ⌘R) refreshes quota and history together.
- [ ] **Step 4: Run** — `make kit-test && make uiux-test && make build`.
- [ ] **Step 5: Commit** — `feat(usage): per-device history charts with approximate costs`.

### Task 7: Cleanup, localization sweep, changelog

**Files:**
- Modify: `Resources/Localizable.xcstrings` (retire "Needs grazr" + tooltip keys if unreferenced; add any missing en/zh-Hans), `CHANGELOG.md`

- [ ] **Step 1:** Grep for unreferenced usage keys; remove only provably dead ones; verify en+zh-Hans parity for every live key (`python3` key-order + parity check).
- [ ] **Step 2:** CHANGELOG entry under `[Unreleased]` → `### Added`/`### Changed` matching file convention (charts, USAGE column, claude via CLI, grazr removed from usage).
- [ ] **Step 3: Full gates** — `make kit-test && make uiux-test && make build` → green.
- [ ] **Step 4: Commit** — `chore(usage): round-two cleanup and changelog`.

---

## Post-plan notes for executors

- Slice map: T1→①, T2→②, T3+T4→③, T5→④, T6→⑤, T7→⑥ (spec's fork strategy).
- Pinned live shapes (2026-10-13 probes): `claude -p '/usage'` output (Task 1 fixture); claude transcript record (`timestamp`, `requestId`, `message.id`, `message.model`, `usage.input_tokens/cache_creation_input_tokens/cache_read_input_tokens/output_tokens`); codex `token_count` events (round one); opencode `models[]` (Task 4 fixture).
- The stats-row `.task` anchor must sit on a real view (the `600ce7d` empty-Group regression); the round-one production test re-anchors onto the USAGE column in Task 2.
- Do not add project.yml/Package.swift entries — sources are globbed.

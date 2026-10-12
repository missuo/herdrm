# Usage Quota Meters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-provider quota meters (Claude, Codex, Z.AI-via-OpenCode, Gemini) fetched through device-side CLI-local sources — herdrm never authenticates anywhere — shown in a new Usage sheet plus a sidebar footer hint.

**Architecture:** New HerdrKit module (`AgentUsage.swift` types + parsers, `UsageSources.swift` command builders, `UsageStore.swift` TTL/single-flight actor) mirroring the existing grazr device-command pattern (`DeviceFileService.run`). New app files `UsageModel.swift` / `UsageView.swift`; four additive edits to existing files.

**Tech Stack:** Swift 5 (SwiftUI, AppKit), XCTest, python3 heredocs as device commands (pattern: `Grazr.readerCommand`).

**Spec:** `docs/superpowers/specs/2026-10-12-usage-quota-meters-design.md` — read it first; this plan argues from it.

## Global Constraints

- macOS 14.0 deployment target; no new package dependencies.
- Additive-only fork discipline: new files everywhere except the four pinned edits (AppModel, ContentView, SidebarView, Localizable.xcstrings). No refactors, no reformatting of adjacent lines.
- herdrm performs **zero** provider network calls and reads **no credential files** (never `~/.codex/auth.json`, never `~/.claude/.credentials.json`). All provider contact happens inside CLIs/grazr on-device.
- Reuse `GrazrWindow` (kind/scope/group/remaining/resetsAt) as the window model; do not modify `GrazrAccounts.swift`.
- Device commands run via `DeviceFileService(device:).run(cmd)` (default 30 s timeout; throws on `.tailcat` devices).
- Every user-facing string via `String(localized:)`; add matching keys to `Resources/Localizable.xcstrings` for **en** and **zh-Hans**.
- Tests: XCTest, `@testable import HerdrKit`, fixture JSON as inline multiline strings (pattern: `AgentStatsTests`). Kit tests run with `cd Packages/HerdrKit && swift test`.
- Conventional commits, one slice per task, each slice compiles + tests green.

## Review Focus

Inputs/failure modes the task tests don't already pin — each gets a test in the owning task:

1. **Codex sessions exist but carry no `rate_limits` yet** → card state `unknown`, not a crash — Task 1 (`testCodexRecordWithoutRateLimitsYieldsUnknown`).
2. **Codex `window_minutes` outside {300, 10080}** (spike saw 43200) → group label `"30d"`, remaining `100 − used_percent`, never garbage — Task 1 (`testCodexMonthlyWindowLabelAndRemaining`).
3. **grazr absent on a device** (`installed: false`) → Claude card `notInstalled`, other providers unaffected — Tasks 1 & 5.
4. **Tailcat device** → `DeviceFileService.run` throws immediately → provider state `failed`, sheet never hangs — Task 4 (`testTailcatDeviceMapsToFailedState` via injected runner).
5. **Concurrent refresh + expired cache** → exactly one command per device×provider — Task 3 (`testSingleFlightDeduplicatesConcurrentLoads`, `testExpiredCacheRerunsCommand`).

---

### Task 1: AgentUsage model + parsers

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/AgentUsage.swift`
- Create: `Packages/HerdrKit/Sources/HerdrKit/UsageSources.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/AgentUsageTests.swift`

**Interfaces:**
- Consumes: `GrazrReport`, `GrazrAccount`, `GrazrWindow` from `GrazrAccounts.swift`.
- Produces (Task 2–6 rely on these exact names):
  - `enum UsageProvider: String, CaseIterable, Sendable { case claude, codex, opencode, gemini }`
  - `struct UsageTokens: Equatable, Sendable { var input, output, reasoning, cacheRead, cacheWrite: Int; var periodStart, periodEnd: Date? }`
  - `struct AgentUsageReading: Equatable, Sendable, Identifiable { var id: String; var provider: UsageProvider; var account: String?; var windows: [GrazrWindow]; var tokens: UsageTokens?; var fetchedAt: Date }`
  - `struct UsageParseResult: Equatable, Sendable { var installed: Bool; var readings: [AgentUsageReading] }`
  - `enum UsageSource { static func parse(_ provider: UsageProvider, stdout: Data, fetchedAt: Date) -> UsageParseResult? }` — `nil` when stdout is not decodable JSON.
  - `enum UsageProviderState: Equatable, Sendable { case loading; case readings([AgentUsageReading]); case notInstalled; case unknown; case failed(String) }` + `UsageProviderState(parse:fetchedAt:)` mapping: `installed == false → .notInstalled`, `readings.isEmpty → .unknown`, else `.readings`.

- [x] **Step 1: Write failing tests** in `AgentUsageTests.swift`:

  - `testGrazrReportYieldsOneReadingPerAccount` — fixture: minimal grazr report JSON with `installed: true`, `active: "a1"`, two accounts (`a1` w/ one session window `remaining 12`, `a2` w/ weekly window); assert `parse(.claude, …)` gives `readings.count == 2`, first account name matches, `windows[0].group == "session"`, `remaining == 12`.
  - `testGrazrAbsentMeansNotInstalled` — `installed: false` fixture → `UsageParseResult.installed == false`, empty readings; `UsageProviderState(parse:)` → `.notInstalled`.
  - `testCodexRecordParsesWindowsAndTokens` — fixture is the spike's real record (trimmed):
    ```json
    {"installed": true, "updated": "2026-10-08T17:32:27.332Z",
     "windows": [{"used_percent": 2.0, "window_minutes": 43200, "resets_at": 1794069902}],
     "tokens": {"input": 4612440, "output": 9838, "reasoning": 5146,
                "cache_read": 4441088, "cache_write": 0}}
    ```
    assert one window: `group == "30d"`, `remaining == 98`, `resetsAt == Date(timeIntervalSince1970: 1794069902)`; `tokens?.input == 4_612_440`.
  - `testCodexMonthlyWindowLabelAndRemaining` — same window asserted via `GrazrWindow.label` contains `"30d"`; a `window_minutes: 300` fixture maps `group == "session"`, `10080` → `"weekly"`.
  - `testCodexRecordWithoutRateLimitsYieldsUnknown` — `{"installed": true, "windows": [], "tokens": {...}}` → `.unknown` state.
  - `testOpencodeStatsParsesTokens` — fixture trimmed from live `opencode stats --json --days 7` (range from/to in ms, tokens block incl. `cache: {read, write}`); assert `tokens?.cacheRead`, `periodStart/End` from ms epochs.
  - `testGeminiAggregateParsesTokens` — normalized snippet output `{"installed": true, "tokens": {"input": 1, "output": 2, "reasoning": 0, "cache_read": 3, "cache_write": 0}, "files": 2}` → tokens mapped.
  - `testUndecodableStdoutReturnsNil` — `Data("".utf8)` → `parse(...) == nil`.

- [x] **Step 2: Run tests, verify they fail**

  Run: `cd Packages/HerdrKit && swift test --filter AgentUsageTests`
  Expected: FAIL — types not found.

- [x] **Step 3: Implement**

  `AgentUsage.swift`: the five types above. Codex window mapping (exact): `group = minutes == 300 ? "session" : minutes == 10080 ? "weekly" : "\(minutes / 1440)d"`; `remaining = max(0, 100 - Int(used.rounded()))`; `kind = "usage"`; `scope = nil`.
  `UsageSources.swift`: `parse` per provider — claude decodes `GrazrReport` (readings = one per account, `account: account.name`, `windows: account.windows`, `tokens: nil`); codex/opencode/gemini decode the normalized DTOs above into one reading each (`account: nil`, except opencode: account from Task 2's auth section, `"Z.AI Coding Plan"` when listed). Any decode failure → `nil`.

- [x] **Step 4: Run tests, verify pass**

  Run: `cd Packages/HerdrKit && swift test --filter AgentUsageTests`
  Expected: PASS (8 tests).

- [x] **Step 5: Commit** — `git add Packages/HerdrKit/Sources/HerdrKit/AgentUsage.swift Packages/HerdrKit/Sources/HerdrKit/UsageSources.swift Packages/HerdrKit/Tests/HerdrKitTests/AgentUsageTests.swift && git commit -m "feat(usage): provider readings model and parsers"`

### Task 2: Device-side command builders

**Files:**
- Modify: `Packages/HerdrKit/Sources/HerdrKit/UsageSources.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsageSourcesTests.swift`

**Interfaces:**
- Consumes: `SSHTunnel.remotePathExport`; `DeviceFileService(device: .local).run(_:timeout:)`; `Device.local`.
- Produces: `enum UsageSource { static func command(for provider: UsageProvider) -> String? }` — `nil` for `.claude` (the store composes grazr's existing commands). Commands print exactly the normalized JSON Task 1 parses. All snippets must honor `$HOME` so tests can point them at fixture trees.

- [x] **Step 1: Write failing tests**:

  - `testCodexCommandReadsFixtureHome` — build a temp dir (`FileManager` temp + `sessions/rollout-x.jsonl` containing the spike record line), run `DeviceFileService(device: .local).run("HOME=\(tmp) " + UsageSource.command(for: .codex)!)`, decode via `UsageSource.parse(.codex, …)`; assert one `"30d"` window. Skips (`XCTSkip`) if python3 absent.
  - `testCodexCommandOnEmptyHomeIsInstalledFalseWithNoWindows` — empty temp HOME → `installed == true` is WRONG here: assert `installed == false` (no `~/.codex`).
  - `testGeminiCommandAggregatesFixtureUsageFiles` — temp HOME with `.gemini/tmp/<hash>/usage.json` files holding `{"total": {"tokens": {"input": 2, "output": 1, "cached": 3}}}`; assert summed tokens (`cache_read == 6` for two files). Two files whose second is invalid JSON → still sums the valid one (skip-on-parse-failure).
  - `testOpencodeCommandRunsWhereInstalled` — `XCTSkipUnless(command -v opencode)` equivalent (`which` via `Process`); run the built command; assert parse yields tokens with nonzero `input`. Assert the built string starts with `SSHTunnel.remotePathExport` (PATH on remote) and contains `auth list` after a `---AUTH---` separator echo.

- [x] **Step 2: Run tests, verify they fail** — `cd Packages/HerdrKit && swift test --filter UsageSourcesTests` → FAIL (command builders absent).

- [x] **Step 3: Implement `command(for:)`** — three commands, each `SSHTunnel.remotePathExport + "\n" +` body:

  - **codex** (exact body):
    ```python
    python3 - <<'USAGE_EOF'
    import glob, json, os
    sessions = os.path.join(os.path.expanduser("~"), ".codex", "sessions")
    report = {"installed": os.path.isdir(sessions), "windows": [], "tokens": None, "updated": None}
    files = sorted(glob.glob(os.path.join(sessions, "**", "*.jsonl"), recursive=True), key=os.path.getmtime) if report["installed"] else []
    for path in reversed(files[-20:]):
        for line in reversed(open(path, errors="replace").read().splitlines()):
            try: rec = json.loads(line)
            except Exception: continue
            payload = rec.get("payload") or {}
            if payload.get("type") != "token_count": continue
            info, limits = payload.get("info") or {}, payload.get("rate_limits") or {}
            total = info.get("total_token_usage") or {}
            report["tokens"] = {"input": total.get("input_tokens"), "output": total.get("output_tokens"),
                                "reasoning": total.get("reasoning_output_tokens"),
                                "cache_read": total.get("cached_input_tokens"),
                                "cache_write": total.get("cache_write_input_tokens")}
            report["updated"] = rec.get("timestamp")
            report["windows"] = [w for side in ("primary", "secondary")
                                 if isinstance((w := limits.get(side)), dict)
                                 and isinstance(w.get("used_percent"), (int, float))]
            break
        else: continue
        break
    print(json.dumps(report))
    USAGE_EOF
    ```
  - **gemini** (exact body): python3 heredoc globbing `$HOME/.gemini/tmp/*/usage.json`, mtime-newer-than-7-days filter, summing `total.tokens.{input,output,cached}` per file into the normalized schema (`reasoning`/`cache_write` = 0), skipping files that fail to parse; `installed` = `~/.gemini` exists.
  - **opencode**: `if command -v opencode >/dev/null 2>&1; then opencode stats --json --days 7; echo; echo ---AUTH---; opencode auth list; else echo '{"installed": false}'; fi`

  Swift-side: opencode parsing splits stdout at the `---AUTH---` marker when present (the marker is absent on `installed: false` output and in Task 1's plain fixtures — parsing must tolerate both); account = `"Z.AI Coding Plan"` iff that row appears.

- [x] **Step 4: Run tests, verify pass** — `cd Packages/HerdrKit && swift test --filter UsageSourcesTests` → PASS.

- [x] **Step 5: Commit** — `git commit -m "feat(usage): device-side usage commands for codex, gemini, opencode"` (add the two files first).

### Task 3: UsageStore — TTL cache + single-flight

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/UsageStore.swift`
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `UsageSource.command(for:)`, `UsageSource.parse`, `Grazr.refreshCommand`, `Grazr.readerCommand`, `Device` (`Identifiable`, `device.id`).
- Produces: `actor UsageStore { init(runner: @escaping (String, Device) async throws -> Data = { try await DeviceFileService(device: $1).run($0) }, now: @escaping () -> Date = { Date() }); func reading(_ provider: UsageProvider, on device: Device, force: Bool = false) async throws -> UsageParseResult }` — 300 s TTL; in-flight task reuse per `"\(device.id):\(provider.rawValue)"`; errors clear both cache and in-flight (retryable); `.claude` runs `readerCommand` normally and `refreshCommand` then `readerCommand` when `force`.

- [x] **Step 1: Write failing tests** (`UsageStoreTests.swift`, injecting a recording runner and mutable clock):
  - `testSingleFlightDeduplicatesConcurrentLoads` — runner sleeps 100 ms; two parallel `reading(.codex, on: .local)`; assert runner call count == 1, both results equal.
  - `testExpiredCacheRerunsCommand` — advance injected clock 301 s; second call re-runs (count 2).
  - `testFreshCacheServesWithoutRunning` — second call within TTL → count stays 1.
  - `testFailedRunIsRetryable` — runner throws once then succeeds; first call throws, second succeeds (no poisoned cache).
  - `testClaudeForceRunsRefreshThenReader` — `force: true` on `.claude`; assert command sequence `[refreshCommand, readerCommand]`; without force → `[readerCommand]`.

- [x] **Step 2: Run, verify fail** — `swift test --filter UsageStoreTests` → FAIL.
- [x] **Step 3: Implement** — actor with `cache: [Key: (at: Date, result: UsageParseResult)]`, `inFlight: [Key: Task<UsageParseResult, Error>]`; on Task completion remove from `inFlight`, store on success only.
- [x] **Step 4: Run, verify pass.**
- [x] **Step 5: Commit** — `feat(usage): single-flight usage store with five-minute cache`.

### Task 4: UsageModel + AppModel/ContentView hooks

**Files:**
- Create: `Sources/HerdrM/UsageModel.swift`
- Modify: `Sources/HerdrM/AppModel.swift` (one `@Published var usageDevice: Device?` beside `grazrAccountsDevice`)
- Modify: `Sources/HerdrM/ContentView.swift` (+1 line beside the grazr `.sheet` at ~line 101)
- Modify: `Resources/Localizable.xcstrings` (state strings, en + zh-Hans)
- Test: `Packages/HerdrKit/Tests/HerdrKitTests/AgentUsageTests.swift` (state-mapping tests live here)

**Interfaces:**
- Consumes: `UsageStore`, `UsageProviderState`, `UsageProvider.allCases`.
- Produces: `@MainActor final class UsageModel: ObservableObject { @Published private(set) var states: [UUID: [UsageProvider: UsageProviderState]]; func refresh(_ device: Device, force: Bool = false) async }` — TaskGroup over providers; catch → `.failed(String(localized: …))`; `AppModel.usageDevice` drives the sheet (Task 5) and the hint (Task 6).

- [x] **Step 1: Write failing tests** — extend `AgentUsageTests`: `testTailcatDeviceMapsToFailedState` uses `UsageStore(runner:)` injection whose closure asserts it is never called and rethrows; `UsageModel`-level mapping is covered by `testProviderStateFromParse` variants (Task 1 already added the pure mapping tests).
- [x] **Step 2: Run, verify fail.**
- [x] **Step 3: Implement** — `UsageModel` owns a `UsageStore` singleton; per device UUID it stores provider states; `refresh` never throws. AppModel gains the one published property (no logic — keep the fork diff minimal). ContentView gains `.sheet(item: $model.usageDevice) { device in UsageView(model: .init(), anchor: device) }` — view arrives in Task 5; until then present a minimal placeholder `EmptyView` extension in UsageModel.swift deleted by Task 5. *(If the placeholder offends, fold this task's sheet line into Task 5 — the AppModel property still lands here.)*
- [x] **Step 4: Build + run tests** — `make kit-test && make build` → green.
- [x] **Step 5: Commit** — `feat(usage): per-device provider state model and sheet hook`.

### Task 5: UsageView sheet

**Files:**
- Create: `Sources/HerdrM/UsageView.swift`
- Modify: `Resources/Localizable.xcstrings`
- Test: `Tests/HerdrMTests/UsageViewTests.swift` (follow `SidebarAgentStatsUIUXTests`/`SidebarHarness` conventions)

**Interfaces:**
- Consumes: `UsageModel.states`, `AgentUsageReading`, `GrazrWindow.left(now:)`/`label`, `GrazrStyle.time(_:now:)`, `Theme`, `SheetHeader`/`SheetSectionLabel` (ContentView.swift:1097/1123).
- Produces: `struct UsageView: View` — sheet content; `UsageProviderCard` (private), `UsageWindowMeter` (private: label, `ProgressView(value: Double(left)/100)`, reset time via `GrazrStyle.time`).

- [x] **Step 1: Write failing UIUX tests** — render `UsageView` with injected states for: loading, `.readings` (claude 2 accounts + codex `"30d"` window + opencode tokens), `.notInstalled`, `.failed("offline")`; assert each card's accessibility labels exist (`accessibilityLabel` per card: `"Claude"`, `"Codex"`, …) and window meters expose `"98% left"`.
- [x] **Step 2: Run, verify fail** — `make uiux-test` → FAIL.
- [x] **Step 3: Implement** — one section per device (local first, then sidebar order), cards in `UsageProvider.allCases` order; claude renders one account row per reading (name, plan windows); tokens cards show `UsageTokens` formatted `input/output/cache` with a "usage" caption (never "quota"); footer shows `fetchedAt` age; ⌘R triggers `refresh(force: true)` on visible devices; remove Task 4's placeholder.
- [x] **Step 4: Run** — `make uiux-test && make build` → green.
- [x] **Step 5: Commit** — `feat(usage): usage sheet with provider meter cards`.

### Task 6: Sidebar footer hint + changelog

**Files:**
- Modify: `Sources/HerdrM/SidebarView.swift` (hint line in the stats block above `footer`, ~lines 175–184)
- Modify: `Resources/Localizable.xcstrings`
- Modify: `CHANGELOG.md` (follow the existing entry style)
- Test: `Tests/HerdrMTests/UsageHintTests.swift`

**Interfaces:**
- Consumes: `UsageModel.states` (fresh readings only), `GrazrWindow.left(now:)`/`label`, `GrazrStyle.time`, `AppModel.usageDevice`.
- Produces: `struct UsageHintLine: View` — tightest open window across all devices/providers (`min` of `left(now:)` among windows with `isOpen`), rendered `"\(label) \(n)% · \(GrazrStyle.time(resetsAt, now: now))"` in the severity color grazr windows use; tap sets `model.usageDevice` to that window's device; renders nothing without fresh readings.

- [ ] **Step 1: Write failing test** — inject states (two devices, windows 12% and 47% open, one closed) → hint shows `12%`; no fresh states → view is `EmptyView`-equivalent (frame zero content).
- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the hint; insert `UsageHintLine` directly above `SidebarMachineStats` in the same padded block; add localization keys (en + zh-Hans); append the CHANGELOG entry under an `Unreleased`/next-version heading matching file convention.
- [ ] **Step 4: Run everything** — `make kit-test && make uiux-test && make build` → green.
- [ ] **Step 5: Commit** — `feat(usage): sidebar hint with tightest open window; changelog`.

---

## Post-plan notes for executors

- Commit slices map to the spec's fork strategy ①–⑤ (Tasks 1→①, 2→②, 3→③, 4+5→④, 6→⑤).
- The Codex record shape was pinned by a live spike on 2026-10-12 (`~/.codex/sessions/rollout-2026-10-08…jsonl`, `payload.rate_limits.primary`: `used_percent 2.0`, `window_minutes 43200`, `resets_at 1794069902`). If Codex changes the schema, only `UsageSources.swift`'s codex DTO changes.
- Gemini's `usage.json` does not exist on the author's machine (Gemini CLI version-dependent). The card will read `unknown`/no-data there by design; the fixture covers the normalized shape.
- Do not add project.yml/Package.swift entries — sources are globbed.

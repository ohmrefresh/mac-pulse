# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Mac Pulse: native macOS menu-bar system monitor. Spec: `docs/prd/Mac Pulse — Product Requirements Document (PRD).md` (mockup: `docs/prd/mockup.png`). Domain terms: `CONTEXT.md` — use its vocabulary (e.g. Health Level, never "Degraded"). Decisions: `docs/adr/`.

Stack: Swift 6, SwiftUI + AppKit (`NSStatusItem`, `NSPopover`), macOS 14+, GRDB.swift for history. Distributed via Developer ID, **unsandboxed** (ADR 0001).

## Commands

All non-UI code is in the SwiftPM package `Packages/MacPulseKit`:

```sh
cd Packages/MacPulseKit
swift build
swift test                                   # all tests (swift-testing)
swift test --filter HealthTests              # one suite
swift test --filter HealthTests/thermalMapping   # one test
PULSE_BENCH=1 swift test -c release --filter CollectorBenchmarks   # per-call cost budgets (opt-in)
```

App target: `MacPulse.xcodeproj` is **generated** from `project.yml` by XcodeGen and gitignored. Never edit the `.xcodeproj`; change `project.yml` and regenerate.

```sh
xcodegen generate
xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/MacPulse.app
```

Overhead gate (PRD §18 budgets; builds Release, launches, measures CPU/RSS):

```sh
scripts/soak.sh                 # 1 h
DURATION=300 scripts/soak.sh    # quick check
```

Packaging (ADR 0001): `scripts/package.sh` builds Release, re-signs with hardened runtime (and verifies the flag), and writes `dist/MacPulse-<version>.dmg`. Without `DEVELOPER_ID` it is an ad-hoc local test build; with `DEVELOPER_ID` + `NOTARY_PROFILE` it signs, notarizes and staples. Version comes from `MARKETING_VERSION` in `project.yml`; the build number is `git rev-list --count HEAD`.

Releasing: bump `MARKETING_VERSION` and add a `## [X.Y.Z]` CHANGELOG section, push, then push tag `vX.Y.Z`. The `release` job in `ci.yml` runs after `test` passes, fails if the tag and `MARKETING_VERSION` differ or the CHANGELOG section is missing, packages, and publishes a GitHub Release (0.x as pre-release). It signs and notarizes only when secrets exist: `DEVELOPER_ID_P12_BASE64` + `DEVELOPER_ID_P12_PASSWORD` + `DEVELOPER_ID` (identity name) to sign; add `NOTARY_KEY_P8_BASE64` + `NOTARY_KEY_ID` + `NOTARY_ISSUER_ID` (App Store Connect API key) to notarize. Without them the DMG is ad-hoc signed and the notes say so.

Opt-in live network test: `PULSE_NET=1 swift test --filter InternetPingTests`.

App sources: `App/Sources`; app-layer tests (`MacPulseTests`, hosted in the app) in `App/Tests`: `xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -destination "platform=macOS" test`. The app skips all monitoring when `XCTestConfigurationFilePath` is set, so tests never touch the real history database.

If Xcode reports that a package symbol doesn't exist when `swift test` sees it, its cached package build is stale: delete `.build/xcode-dev` (or the relevant derived-data folder) and rebuild.

CI: `.github/workflows/ci.yml` (package tests, app build + tests, informational benchmarks; on `v*` tags, a `release` job that publishes the DMG). `LSUIElement` = true (menu-bar only, no Dock icon).

## Architecture

Module dependency chain (targets in `Packages/MacPulseKit`, then the app):

`PulseCore` ← `PulseCollectors`, `PulseStore` ← `PulseEngine` ← `MacPulse` app

- **PulseCore** — metric types, `HealthLevel`, `Connectivity`, thresholds and Health Mapping. No dependencies.
- **PulseCollectors** — one collector per metric family over C/IOKit APIs. Delta/parse math is split into pure functions (`CPUUsage`, `NetworkRate`, `CPUTimeTracker`, `PSParser`, `BatteryCollector.parse`) and tested with fixtures; syscall paths get live plausibility tests.
- **PulseStore** — GRDB history: in-memory buffer flushed every 30s; tiers `samples_1s` (1h) → `agg_10s` → `agg_1m` → `agg_5m` storing min/avg/max.
- **PulseEngine** — single coalesced scheduler, alert state machine, timeline generator, diagnostics rules.
- **MacPulse** — UI only. Single process; no daemon.

Built so far: `PulseCore` (incl. `AlertRule` + PRD §12 templates, `TimelineEvent`); `PulseCollectors` (CPU, memory, network, disk, battery, thermal, processes, ICMP ping, DNS probe; Phase 3: `ListeningPortsCollector` (netstat), `DevRuntime`, `NetworkConfigCollector` (VPN/proxy), `PublicIPLookup`, `DockerClient` (Unix-socket HTTP/1.0); Phase 4: `GPUCollector`, `PeripheralBatteryCollector`, `SensorsCollector` (private HID temps + SMC fans, ADR 0002), `SystemInfoCollector` (core clusters, load average, boot time), `IOReportClient` (private CPU frequency + GPU power, ADR 0003)); `PulseStore` (`HistoryStore` GRDB tiers + timeline events + `chartSeries` (SQL re-bucketing to ≤600 points, keeps min/max; `HistorySeries.segments` splits at gaps), `HistoryRecorder` 30 s buffered writes); `PulseEngine` (`Cadence` + `Sampler` and `Prober` actors → `LiveMetrics` on the main actor, `AlertEngine` state machine, `TimelineGenerator` (debounced events; heuristics in `TimelineConfig`), `DiagnosticRules` + `DiagnosticsRunner` (15 min history + probe burst), `DeveloperMonitor` actor (Docker/ports/VPN/proxy/public IP), `HistorySamples`, `MenuBarFormatter`, `RecentSeries`). App: status item, popover, dashboard (all sections incl. Timeline; Overview has Recent Activity), Alerts UI + `AlertNotifier`, Diagnostics sheet (⌘R), Developer section, Sensors with °C/fans/GPU, accessory batteries, history charts on Performance/Network (`ChartRange` Live/1h…30d, `HistoryChart`), sleep/wake events, Settings incl. retention + clear history. Wi-Fi SSID changes are deliberately not in the timeline (needs Location Services permission).

Alerts: templates are seeded **disabled**; notification permission is requested only when the user first enables a rule. Alert fire/resolve events go to the single `timeline_events` table (no separate alerts table).

History: `MetricKind` raw values are persisted — never rename a case, only add. `LiveMetrics(recorder:)` takes the recorder by injection; tests pass none so they never touch the real database (`~/Library/Application Support/MacPulse/history.sqlite`).

UI look follows `docs/prd/mockup.png` in system Light/Dark. Shared kit in `App/Sources/Components.swift`: `MetricStyle` (one tint + SF Symbol per metric — use it, don't pick colors ad hoc), `Sparkline`, `MetricCard`, `FooterStats`, `PageHeader` (every dashboard section draws its own large title; the window title is hidden), `SubsectionHeader`, `cardBackground()`, `AppLogo`, `IconCache`, `StatRail`, `DeltaLabel`, `DonutChart`, `ChartWithRail`. **Never show a value we don't measure** (e.g. disk category split): a figure this Mac cannot report has its row *hidden* (`StatRail` drops nil rows), never dashed or guessed. Multi-part charts of one metric family (memory ring/bands, per-core lines) use `MetricStyle.shade(_:of:)`, not ad-hoc hues.

App UI rule: popover and dashboard host SwiftUI inside AppKit (`NSPopover`, `NSWindow`) and drop their hosting controller on close, so hidden UI never re-renders. Any view that shows a process list must call `metrics.processListAppeared()/processListDisappeared()` (reference-counted) to get 1 s scans. Add other targets to `Package.swift` (and as `project.yml` dependencies) as they are built.

## Invariants

- **Overhead budgets (PRD §18) are hard limits:** idle CPU <1%, memory <150 MB (physical footprint as `footprint`/Activity Monitor report it — not RSS, which counts shared framework pages), network <1 MB/h, popover <150 ms, UI update <250 ms. Process scans run at 5s in background, 1s only while the popover/Processes tab is visible.
- **Scope:** v1.0 = PRD Phase 1 + Phase 2. Phase 1 is internal milestone M1. Phases 3–4 are post-1.0.
- **Thresholds are user-configurable** — alert rules, network latency/loss, CPU Health Level and diagnostics limits all live in Settings (`AppSettings` → `LiveMetrics.configureNetwork/setCPUThresholds/setDiagnosticsLimits`). Only heuristics in `TimelineConfig` (process hog / memory growth) are internal.
- **Alerts:** Inactive → Pending → Firing → Resolved; resolving needs the condition false for the same duration; notify once per firing, 10-min cooldown.
- **Diagnostics:** deterministic rules only. Every Finding has Observed / Possible cause / Recommendation; `PossibleCause` only has `.likely`/`.possibly` cases, so an unhedged cause can't be expressed — keep it that way.
- **Temperature:** `ProcessInfo.thermalState` is the only thermal signal that drives Health Level; °C from the private sensors (ADR 0002) is informational and shown alongside it.
- **Private readings fail soft:** sensors (ADR 0002) and frequency/GPU power (ADR 0003) are all-optional. A value this Mac cannot report is hidden, never dashed or guessed, and nothing outside its own page depends on it. DVFS ladders are matched to clusters by shape (entry count, ascending, 0.1–7 GHz) because the `voltage-states*` names do not identify their device; energy units are read per channel (CPU mJ, GPU nJ on the same Mac).
- **Process list is hybrid:** an unprivileged app cannot read root/system processes (~⅓ of all, incl. WindowServer). `ProcessCollector` reads its own user's processes via `proc_pid_rusage`, and fills the rest from setuid `/bin/ps` every 5 s. Don't replace `ps` with a privileged helper without an ADR.
- **Menu-bar CPU cost is mostly AppKit**, not collectors: each title change relayouts the menu bar. Size the status item to the title it draws and write both the title and `length` only when they change, so a relayout costs a digit-count change rather than a tick. Menu-bar icons are static template SF Symbol attachments (optional, "Show icons"); compare the stored plain-text key, not `button.title` (attachments add placeholder characters). No sparklines or colors in the menu bar.
- **Performance page gate:** `performanceAppeared()`/`performanceDisappeared()` (reference-counted, like the process-list and sensor gates) speeds the GPU job from 5 s to the base interval while that page is visible. Load average is on the always-on 1 s job because `load1` is persisted at every chart range. Per-core and the memory split are live-only: history stores `cpu`, `mem`, `swap`, `gpu` and `load1`, so stored ranges fall back to the combined line with a caption.
- **Event-driven refresh:** `SystemEventSources` (memory pressure, thermal, power source) and the app's disk mount/unmount observers call `expedite`, so those metrics update within a second instead of waiting for their cadence.
- **Phase 3/4 cadences:** sensors cost ~20 ms (HID IPC per sensor; one service per name, `tdev` skipped) → every 60 s, 15 s while the menu bar shows °C, 5 s while a temperature view calls `sensorsAppeared()`. Docker list every 30 s; Docker stats and listening ports only while the Developer view is visible (`developerAppeared()`). Public IP is opt-in (off by default) and only contacts 1.1.1.1.
- **SMC struct layout:** `SMCConnection.KeyData` must be exactly 80 bytes; `KeyInfo` has explicit padding because Swift otherwise packs following fields into its tail.
- **Menu-bar-only operation** must stay fully functional; nothing critical may depend on the dashboard window.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).

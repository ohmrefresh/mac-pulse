# Changelog

Notable changes to Mac Pulse. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project is pre-1.0, so the public surface may still change between minor versions.

## [0.1.1] — 2026-09-28

First build published as a download. It is ad-hoc signed and not notarized, so macOS blocks the first launch: right-click Mac Pulse in Applications and choose Open.

### Fixed

- The app reports its real version and build number. 0.1.0 identified itself as version 1.0, build 1.
- Builds with the Xcode on GitHub's macOS runners. Four expressions that newer compilers accept took the runner's Swift 6.2 too long to type-check: two test expectations, the CPU statistics list and the time-series chart.
- The GPU model-name test is skipped, not failed, on a Mac with no GPU to read, such as a virtual machine.

### Added

- Pushing a version tag tests the app, builds the disk image and publishes it as a GitHub release, with that version's section of this changelog as the notes. Versions before 1.0 are marked as pre-releases.
- The build number counts commits, so every release has a higher one than the last.

## [0.1.0] — 2026-09-28

First pre-release. Everything below is new. No signed or notarized build is published yet — build from source.

### Menu bar and popover

- Status item with up to eight selectable segments: CPU, memory, network throughput, internet latency, battery, thermal state, CPU temperature and GPU. Four are on by default.
- Optional static SF Symbol icons per segment. No sparklines, no colour — the menu bar stays quiet.
- The item is sized to the title it draws, and the title and width are written only when they change, so a refresh costs a digit change rather than a full menu-bar relayout.
- Popover with CPU, memory, network and temperature rows — battery too on Macs that have one — each with a sparkline and a Health Level badge, plus Top Processes by CPU, Settings and Quit.

### Dashboard

- Ten sections: Overview, Performance, Network, Processes, Developer, Storage, Battery, Sensors, Timeline and Alerts.
- Overview leads with what is actually wrong rather than six equal cards, and carries Recent Activity.
- Performance shows CPU per core, load average or combined, plus GPU, a memory donut with bands, and CPU frequency and GPU power.
- Network covers throughput, latency, packet loss and connection health.
- Processes is a sortable table with search.
- Storage, Battery — including accessory batteries — and Sensors with temperatures, fans and thermal state.
- History charts on Performance and Network across Live, 1 h, 6 h, 24 h, 7 d and 30 d.
- Runs entirely from the menu bar if you never open it; the dashboard is optional.

### Monitoring

- Collectors for CPU, memory, network, disk, battery, thermal state, processes, ICMP ping and DNS.
- Developer monitoring: Docker containers and stats, listening ports, language runtimes, VPN and proxy configuration, and an opt-in public IP lookup that only ever contacts 1.1.1.1.
- Hardware readings: GPU, peripheral batteries, HID temperature sensors, SMC fan speeds, core clusters, load average and boot time.
- CPU frequency and GPU power read through IOReport, with DVFS ladders matched to clusters by shape and energy units read per channel.
- Hybrid process list: the app reads its own user's processes directly and fills in the rest from `/bin/ps`, since an unprivileged app cannot read root and system processes.
- A single coalesced scheduler with visibility gates — process scans drop to 1 s only while a process list is on screen, sensors and the GPU speed up only while their pages are visible.
- Event-driven refresh on memory pressure, thermal state, power source and disk mount changes, so those update within a second instead of waiting for their cadence.

### History, timeline, alerts and diagnostics

- Persistent history in SQLite with tiered rollups — 1 s samples for an hour, then 10 s, 1 m and 5 m aggregates keeping min, average and max — written in 30 s buffered flushes. Retention is configurable from 1 hour to 30 days, and history can be cleared.
- Timeline of what changed and when, debounced, with range and category filters. A single busy process can no longer fill it.
- Alert rules with eight templates, all seeded disabled. States run Inactive → Pending → Firing → Resolved, resolving requires the condition to be false for the same duration, and each firing notifies once with a 10-minute cooldown. Notification permission is requested only when you first enable a rule.
- Diagnostics (⌘R) over the last 15 minutes plus a probe burst. Rules are deterministic and every Finding states Observed, Possible cause and Recommendation — causes are hedged as likely or possible, never asserted.

### Settings

- Sampling interval, launch at login and an optional Dock icon.
- Per-metric menu bar selection and icon toggle.
- Ping host, latency and packet-loss thresholds, and the public IP opt-in.
- CPU Health Level thresholds and diagnostics limits for gateway, DNS, disk and CPU temperature.
- History retention and storage location.

### Design and accessibility

- A documented design system: one tint and SF Symbol per metric, metric shades stepped in OKLCH away from the background, and multi-part charts of one metric family drawn from that scale rather than ad-hoc hues.
- Severity is legible in greyscale, so colour is never the only signal.
- Hardened against locale differences, screen readers and extreme values.
- A value this Mac cannot report is hidden, never dashed or guessed.

### Packaging and CI

- `scripts/package.sh` builds a DMG, re-signs with the hardened runtime and verifies the flag; with a Developer ID and notary profile it signs, notarizes and staples, and without one it produces an ad-hoc local build only.
- `scripts/soak.sh` measures idle CPU and memory against the overhead budgets.
- CI runs package tests, the app build and its tests, plus informational collector benchmarks.

### Decisions

- Distribute outside the Mac App Store without the App Sandbox (ADR 0001), which is what makes a complete process list, the Docker socket, listening ports and network configuration readable.
- Read temperatures and fan speeds through private interfaces, failing soft (ADR 0002).
- Read CPU frequency and GPU power through IOReport, matching DVFS tables by shape (ADR 0003).

### Known limitations

- No signed or notarized release yet.
- Temperature, fan, CPU frequency and GPU power come from private interfaces and are hidden on any Mac or macOS version that does not report them.
- Root and system processes are read from `/bin/ps`, not directly.
- Wi-Fi SSID changes are deliberately not tracked, as that would require Location Services.

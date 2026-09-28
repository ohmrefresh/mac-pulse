# Mac Pulse

A macOS menu-bar system monitor that answers: what is happening to my Mac, when did it start, and what is likely causing it.

## Health

**Health Level**:
The single severity scale shared by every metric card, alert, timeline event, and diagnostic finding: Healthy, Warning, Critical, or Unknown.
_Avoid_: Degraded, status, severity (as separate scales)

**Unknown**:
The Health Level when no data exists yet or a collector failed.
_Avoid_: N/A, error

**Connectivity**:
Whether the Mac can reach the network at all: Online or Offline. Offline forces network Health Level to Critical.
_Avoid_: network status

**Health Mapping**:
The fixed translation from a source scale to Health Level — thermal Nominal/Fair→Healthy, Serious→Warning, Critical→Critical; memory pressure Normal/Warning/Critical one-to-one; Battery Condition Normal→Healthy, Service Recommended→Warning.

**Battery Condition**:
macOS's own verdict on battery wear: Normal or Service Recommended. Independent of charge level.
_Avoid_: battery health (for charge level)

**Thermal State**:
macOS's own four-step thermal scale (Nominal, Fair, Serious, Critical). The only thermal signal that
drives Health Level.
_Avoid_: temperature (°C readings are a separate, informational signal)

## Interface

**Menu Bar**:
The always-visible status item and the segments it draws. The first of the three levels.
_Avoid_: tray, menulet, menu bar app

**Popover**:
The transient panel that opens from the Menu Bar. The second level.
_Avoid_: flyout, dropdown, panel, widget

**Dashboard**:
The full window with the section sidebar. The third level.
_Avoid_: main window, app window, console

## Monitoring

**Metric**:
One measured quantity (CPU %, memory used, download rate, ping, …).

**Sample**:
One timestamped value of a metric at collection cadence.

**Collector**:
The component that reads one metric family from the OS.

**Probe**:
An active network test (ICMP ping or DNS lookup) against a target, as opposed to passive reading.

**Top Processes**:
The top 10 processes by CPU and top 10 by memory at a process scan. The only processes kept in history.

**Primary Interface**:
The network interface carrying the default route (e.g. en0). Throughput is measured on it alone.

**Memory Used**:
App Memory plus Wired plus Compressed — the same figure Activity Monitor calls "Memory Used". Swap is
not part of it: swap lives on disk, not in RAM.
_Avoid_: memory usage (ambiguous), RAM used including cache

**Cached Files**:
RAM holding file contents the system can reclaim on demand. Not part of Memory Used, and not a shortage.
_Avoid_: cache, buffers

**Free Memory**:
Installed RAM minus Memory Used minus Cached Files. Defined as the remainder so that the three always
add up to the installed total.

**Load Average**:
The kernel's count of runnable threads averaged over one, five and fifteen minutes. A count, not a
percentage — it is not capped at 100 and is only comparable to the core count.
_Avoid_: CPU load (that is CPU %)

**Trend**:
A metric's current value minus its own average over the last five minutes, shown as the "vs 5m avg"
delta on a card. Undefined — and therefore not shown — until the metric has been sampled for at least
two and a half minutes.
_Avoid_: change, delta (as separate concepts)

**Thermal State** and **CPU Temperature** are different signals: the first is macOS's own four-step scale and drives Health Level; the second is a °C reading from private sensors and is informational only. Both are shown; only Thermal State affects Health Level.

## Developer

**Local Service**:
A process listening on a TCP port on this Mac, with its reachability: "this Mac only" (loopback) or all interfaces.
_Avoid_: server, daemon (for this concept)

**Runtime**:
A development language or service recognised from a process name (Node.js, Python, PostgreSQL, Docker, …).

**Container**:
A Docker container reported by the local Docker daemon (Docker Desktop, OrbStack or Colima).

**VPN**:
Active when a tunnel interface is the primary route or carries a routable IPv4 address (split tunnel).

**Public IP**:
The address the internet sees, looked up only when the user opts in.

## Hardware

**Sensor**:
A named temperature source read through private interfaces; may be unavailable after a macOS update.
_Avoid_: probe (a Probe is a network test)

**Hottest Sensor**:
The warmest temperature Sensor at a given moment, named. Informational, like every °C reading.

**Fan Speed**:
Revolutions per minute reported by the SMC; 0 means the fan is stopped, which is normal when cool.

**Core Cluster**:
A group of CPU cores the kernel names itself — "Performance", "Efficiency", "Super" — and reports a
count for. The names differ by chip and are read from the machine, never assumed.
_Avoid_: P-cores / E-cores (as fixed names)

## Alerts and history

**Alert Rule**:
A user-configurable condition — metric, comparator, threshold, duration, severity.
_Avoid_: trigger, threshold (for the whole rule)

**Alert States**:
Inactive → Pending → Firing → Resolved. Firing needs the condition held for the full duration; Resolved needs it false for the same duration.

**Timeline Event**:
A recorded moment something changed: a Health Level transition, alert firing/resolving, connectivity change, notable process change, or system event (sleep/wake, power source, thermal).
_Avoid_: log entry, activity

**Template**:
A predefined Alert Rule offered once; editing or deleting it is permanent, and only templates the user has never seen are added later.

**Finding**:
One diagnostic result made of an Observed fact, a Possible cause (always hedged), and a Recommendation.
_Avoid_: diagnosis, root cause

## Delivery

**M1**:
Internal milestone covering PRD Phase 1. Dogfooded, not released.

**v1.0**:
First public release — PRD Phase 1 plus Phase 2.

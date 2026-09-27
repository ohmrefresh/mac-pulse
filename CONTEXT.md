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
The fixed translation from a source scale to Health Level — thermal Nominal/Fair→Healthy, Serious→Warning, Critical→Critical; memory pressure Normal/Warning/Critical one-to-one.

**Thermal State**:
macOS's own four-step thermal scale (Nominal, Fair, Serious, Critical). The only thermal signal in v1.0.
_Avoid_: temperature (°C readings are a separate, later feature)

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

## Alerts and history

**Alert Rule**:
A user-configurable condition — metric, comparator, threshold, duration, severity.
_Avoid_: trigger, threshold (for the whole rule)

**Alert States**:
Inactive → Pending → Firing → Resolved. Firing needs the condition held for the full duration; Resolved needs it false for the same duration.

**Timeline Event**:
A recorded moment something changed: a Health Level transition, alert firing/resolving, connectivity change, notable process change, or system event (sleep/wake, power source, thermal).
_Avoid_: log entry, activity

**Finding**:
One diagnostic result made of an Observed fact, a Possible cause (always hedged), and a Recommendation.
_Avoid_: diagnosis, root cause

## Delivery

**M1**:
Internal milestone covering PRD Phase 1. Dogfooded, not released.

**v1.0**:
First public release — PRD Phase 1 plus Phase 2.

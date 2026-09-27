# Mac Pulse — Product Requirements Document

**Version:** 1.0  
**Status:** Draft for Development  
**Platform:** macOS  
**Product Type:** Native desktop + menu-bar system monitor  
**Target:** Apple Silicon first, Intel macOS supported where practical

---

## 1. Product Summary

Mac Pulse is a macOS system-monitoring and diagnostics application that provides real-time visibility into:

- CPU
- Memory
- Network
- Internet health
- Disk
- Battery
- Thermal state
- Processes
- Historical system health
- Alerts
- Incident diagnostics

The product is inspired by traditional macOS system-monitoring utilities but focuses on a stronger question:

> What is happening to my Mac, when did it start, and what is likely causing it?

The application consists of:

1. Menu-bar metrics
2. Quick monitoring popover
3. Full dashboard
4. Historical timeline
5. Diagnostics engine
6. Rule-based alerts
7. Developer-focused monitoring

---

# 2. Product Goals

## 2.1 Primary Goals

### G-01 — Immediate visibility

Users must be able to understand Mac health from the menu bar without opening Activity Monitor.

### G-02 — Fast troubleshooting

Users must be able to identify:

- CPU saturation
- Memory pressure
- network degradation
- high latency
- packet loss
- thermal issues
- disk capacity problems
- abnormal processes

### G-03 — Historical analysis

Users must be able to answer:

- When did the problem begin?
- Which metric changed first?
- Which process was responsible?
- Was the issue CPU, memory, thermal, or network related?

### G-04 — Low overhead

Mac Pulse must consume minimal CPU, RAM, battery, and network resources.

### G-05 — Developer-friendly diagnostics

The application should later support:

- Docker
- local ports
- development runtimes
- local services
- VPN
- proxy
- DNS
- Kubernetes-related local tooling

---

# 3. Non-Goals for MVP

The MVP will not include:

- manual fan control
- overclocking
- power-limit modification
- full hardware sensor reverse engineering
- remote Mac management
- cloud synchronization
- enterprise fleet management
- antivirus functionality
- process termination automation
- GPU tuning
- Windows or Linux support

---

# 4. Target Users

## Persona P1 — Software Developer

Needs visibility into:

- IDE CPU usage
- Docker resource usage
- Java/Node processes
- memory pressure
- network quality
- localhost services

Example problem:

> Why did my Mac become slow after starting Docker and IntelliJ?

---

## Persona P2 — DevOps / SRE / Platform Engineer

Needs:

- network latency
- packet loss
- DNS health
- VPN status
- system performance
- connectivity incidents

Example problem:

> Is the deployment issue caused by VPN, DNS, Wi-Fi, or the application?

---

## Persona P3 — Power User

Needs:

- CPU
- RAM
- battery
- temperature
- storage
- bandwidth

Example problem:

> Why is my battery draining faster than normal?

---

# 5. Core User Experience

Mac Pulse provides three interaction levels.

## Level 1 — Menu Bar

Example:

```text
CPU 21% | MEM 62% | ↓8.4M ↑1.2M | 18ms | 52°C
```

Users can configure which metrics appear.

---

## Level 2 — Quick Popover

Clicking the menu-bar item displays:

```text
Mac Pulse

CPU             21%      Healthy
Memory          62%      Healthy
Network         ↓8.4M
                ↑1.2M    18ms

Battery         87%
Temperature     52°C

Top Processes

Xcode           12.4%
Chrome           6.1%
WindowServer     4.8%

[ Open Mac Pulse ]
```

---

## Level 3 — Full Dashboard

Navigation:

```text
Overview
Performance
Network
Processes
Storage
Battery
Sensors
Timeline
Alerts
Settings
```

---

# 6. MVP Scope

## Epic E1 — Menu Bar Monitor

Display configurable real-time metrics.

Supported metrics:

- CPU %
- memory %
- network download
- network upload
- latency
- battery %
- thermal state

Users may enable or disable individual values.

---

## Epic E2 — Overview Dashboard

Dashboard cards:

### CPU

Display:

- CPU usage
- per-core usage
- processor name
- current load
- 1-minute trend
- 5-minute average

### Memory

Display:

- used memory
- total memory
- memory pressure
- app memory
- wired memory
- compressed memory
- swap

### Network

Display:

- upload speed
- download speed
- active interface
- ping
- history graph

### Disk

Display:

- total capacity
- used
- available
- application usage
- system usage

### Battery

Display:

- current %
- charging status
- estimated remaining time
- cycle count
- maximum capacity where available

### Thermal

Display:

- macOS thermal state
- available temperature metrics
- historical state

---

# 7. Network Health

Network monitoring is a primary differentiator.

## Metrics

Mac Pulse shall monitor:

- active network interface
- connectivity status
- upload throughput
- download throughput
- gateway latency
- internet latency
- packet loss
- DNS latency

Initial test targets:

```text
Gateway
1.1.1.1
8.8.8.8
Configurable custom target
```

---

## Network Status

Possible status values:

```text
Healthy
Degraded
Offline
Unknown
```

Example rules:

```text
Healthy
ping < 100 ms
packet loss < 2%

Degraded
ping >= 100 ms
OR
packet loss >= 2%

Critical
ping >= 300 ms
OR
packet loss >= 10%
```

Thresholds must be configurable.

---

# 8. Process Monitoring

The system shall display:

- process name
- PID
- CPU %
- memory
- application icon where available
- process owner
- start time where available

Sorting:

- CPU
- memory
- name

Search must be supported.

---

# 9. Timeline

The Timeline is one of the key product differentiators.

Example:

```text
09:12  CPU normal
09:14  Docker CPU increased
09:15  CPU > 80%
09:16  Thermal → Fair
09:17  Memory pressure elevated
09:18  Ping 18 ms → 240 ms
09:20  Thermal → Serious
09:25  CPU normal
```

Timeline event categories:

- CPU
- memory
- network
- disk
- battery
- thermal
- connectivity
- process
- system

---

# 10. Diagnostics

Users may select:

**Run Diagnostics**

The application analyzes recent system metrics.

Example result:

```text
System Health

CPU
Warning

Peak CPU: 94%

Top contributor:
Docker 48%
Xcode 23%

Memory
Warning

Used:
30.1 / 32 GB

Swap:
4.2 GB

Network
Problem detected

DNS:
420 ms

1.1.1.1:
21 ms

Possible cause:
Local DNS resolver is responding slowly.
```

Diagnostics must clearly distinguish:

```text
Observed fact
Possible cause
Recommendation
```

Mac Pulse must not present heuristic conclusions as guaranteed causes.

---

# 11. Alerts

Users may define threshold-based rules.

Example:

```text
CPU > 90%
FOR 30 seconds
```

Actions:

- macOS notification
- timeline event

Supported metrics for MVP:

- CPU
- memory
- disk free space
- ping
- packet loss
- battery
- thermal state

---

# 12. Alert Templates

Default alert templates:

### High CPU

```text
CPU > 90%
for 30 seconds
```

### Memory Pressure

```text
memory pressure = critical
for 15 seconds
```

### Internet Latency

```text
ping > 300 ms
for 20 seconds
```

### Packet Loss

```text
packet loss > 10%
```

### Low Disk

```text
free disk < 10 GB
```

### Thermal Warning

```text
thermal state >= serious
```

---

# 13. History

Required retention presets:

```text
1 hour
6 hours
24 hours
7 days
30 days
```

Sampling strategy:

```text
0–1 hour      1-second samples

1–24 hours    10-second aggregate

1–7 days      1-minute aggregate

7–30 days     5-minute aggregate
```

Users must be able to clear historical data.

---

# 14. Settings

## General

- launch at login
- show Dock icon
- start minimized
- menu-bar mode

## Menu Bar

Enable:

- CPU
- memory
- network
- latency
- battery
- temperature

## Sampling

User selectable:

```text
1 second
2 seconds
5 seconds
```

Default:

```text
1 second
```

## Network

Configure:

- ping host
- DNS server
- test interval
- latency threshold
- packet loss threshold

## Data

Configure history retention.

---

# 15. UX Requirements

Mac Pulse shall follow macOS conventions.

Requirements:

- native window controls
- dark mode
- light mode
- system appearance mode
- keyboard navigation
- native notifications
- support menu-bar-only operation

Primary visual principles:

- dense but readable
- low visual noise
- immediate status recognition
- graphs prioritized over tables
- status colors used conservatively

---

# 16. Navigation

```text
Mac Pulse
│
├── Overview
│
├── Performance
│   ├── CPU
│   └── Memory
│
├── Network
│
├── Processes
│
├── Storage
│
├── Battery
│
├── Sensors
│
├── Timeline
│
├── Alerts
│
└── Settings
```

---

# 17. Keyboard Shortcuts

Recommended:

```text
⌘1     Overview
⌘2     Performance
⌘3     Network
⌘4     Processes

⌘K     Search

⌘,     Settings

⌘R     Run Diagnostics
```

---

# 18. Success Metrics

## Application performance

Target idle Mac Pulse overhead:

```text
CPU:
< 1% average

Memory:
< 150 MB

Disk writes:
minimal / buffered

Network:
< 1 MB/hour excluding active tests
```

---

## User Experience

Dashboard launch:

```text
< 1 second perceived
```

Popover opening:

```text
< 150 ms
```

Metric UI update latency:

```text
< 250 ms after collection
```

---

# 19. Development Phases

## Phase 1 — Core MVP

Implement:

- menu bar
- popover
- CPU
- memory
- network throughput
- ping
- disk
- battery
- process list
- dashboard

---

## Phase 2 — Observability

Implement:

- SQLite history
- timeline
- alerts
- network health
- DNS latency
- packet loss
- diagnostics

---

## Phase 3 — Developer Features

Implement:

```text
Docker monitoring
Listening ports
Local services
VPN detection
Proxy detection
Runtime detection
Public IP
```

---

## Phase 4 — Advanced Hardware

Evaluate:

- Apple Silicon GPU
- hardware sensor temperatures
- fan RPM
- SMART data
- Bluetooth battery
- additional Apple Silicon metrics

---

# 20. MVP Definition of Done

Mac Pulse MVP is complete when a user can:

1. install Mac Pulse
2. launch it from the macOS menu bar
3. see live CPU and memory
4. see upload/download speed
5. see internet latency
6. see battery status
7. see disk status
8. identify top resource-consuming processes
9. open the dashboard
10. view at least 24 hours of history
11. receive configurable alerts
12. run basic diagnostics
13. identify network degradation
14. operate the application with low system overhead
---
name: Mac Pulse
description: A macOS menu-bar system monitor that records what changed, when, and what likely caused it.
colors:
  cpu: "#0088FF"
  memory: "#CB30E0"
  network: "#34C759"
  gpu: "#00C3D0"
  temperature: "#FF8D28"
  disk: "#6155F5"
  developer: "#AC7F5E"
  alert: "#FF383C"
  health-healthy: "#34C759"
  health-warning: "#FF8D28"
  health-critical: "#FF383C"
  surface-window: "#FFFFFF"
  surface-card: "#F5F5F5"
  ink: "#000000D9"
  ink-secondary: "#00000080"
  ink-tertiary: "#00000042"
  hairline: "#0000001A"
typography:
  display:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "26pt"
    fontWeight: 700
    lineHeight: "1.2"
  headline:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "22pt"
    fontWeight: 600
    lineHeight: "1.2"
  title:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "15pt"
    fontWeight: 600
    lineHeight: "1.3"
  body:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "13pt"
    fontWeight: 400
    lineHeight: "1.4"
  label:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "12pt"
    fontWeight: 400
    lineHeight: "1.3"
  caption:
    fontFamily: "SF Pro, -apple-system, system-ui"
    fontSize: "10pt"
    fontWeight: 400
    lineHeight: "1.3"
rounded:
  card: "12px"
  panel: "10px"
  chip: "8px"
  sector: "3px"
spacing:
  hairline-gap: "4px"
  tight: "8px"
  row: "12px"
  section-inner: "16px"
  section: "20px"
  page: "24px"
components:
  metric-card:
    backgroundColor: "{colors.surface-card}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "16px"
  stat-rail-row:
    textColor: "{colors.ink}"
    typography: "{typography.label}"
    height: "24px"
  health-badge:
    backgroundColor: "{colors.health-healthy}"
    textColor: "{colors.health-healthy}"
    rounded: "{rounded.chip}"
    padding: "2px 8px"
    typography: "{typography.caption}"
  button-prominent:
    backgroundColor: "{colors.cpu}"
    textColor: "{colors.surface-window}"
    rounded: "{rounded.chip}"
    padding: "6px 14px"
---

# Design System: Mac Pulse

## 1. Overview

**Creative North Star: "The Flight Recorder"**

Mac Pulse is not a dashboard that decorates telemetry; it is an instrument that keeps the record. The interface exists to answer three questions in order — what is happening, when did it start, what is likely causing it — and every visual decision serves that sequence. Readings are dense, unemotional and timestamped. Colour marks an event, not a mood.

The system is deliberately built from macOS's own materials: Apple's system colors, SF Pro at stock text styles, stock controls. It owns no typeface and no palette. That is the point — a figure the app prints should be checkable against Activity Monitor, and a control should behave the way every other Mac control behaves. Identity comes from *what is shown and what is refused*, not from custom chrome.

What it rejects, in PRODUCT.md's words: **gamer/RGB monitoring skins** (neon gradients, animated gauges, glowing rings), **Activity Monitor's blandness** (unstyled tables with no hierarchy), the **SaaS dashboard template** (hero metric tiles with gradient accents, identical card grids, purple-blue gradients), and **alarmist red-everywhere** (warning colour for routine variation). The first treats telemetry as spectacle; the last destroys the only thing a monitor sells, which is trust that a red state means something.

**Key Characteristics:**
- Flat surfaces, hairline borders, no shadows anywhere
- One tint per metric family, stepped in OKLCH when a chart needs parts
- Status colour reserved for Health Level; never decorative
- Monospaced digits on every figure that changes
- Native controls only — hover, focus and keyboard come from the system
- A value this Mac cannot report is absent, never dashed

## 2. Colors

Apple's system colors, resolved per appearance. Each tint identifies one metric family and does nothing else; status colour is a separate, smaller vocabulary reserved for health.

### Primary

The metric tints. One per family, assigned in `MetricStyle` and never chosen ad hoc at a call site. Dark-appearance values are given second.

- **System Blue — CPU** (`#0088FF` / `#0091FF`): CPU usage everywhere, plus internet latency and upload, which are CPU's siblings in the menu bar's reading order.
- **System Purple — Memory** (`#CB30E0` / `#DB34F2`): memory used, the pressure ring, the stacked memory split.
- **System Green — Network & Battery** (`#34C759` / `#30D158`): download throughput and battery charge. Doubles as Healthy in the status vocabulary; that overlap is deliberate, since both mean "nothing to do here".
- **System Teal — GPU & SSD** (`#00C3D0` / `#00D2E0`): GPU utilisation, GPU power, SSD temperature.
- **System Orange — Temperature** (`#FF8D28` / `#FF9230`): °C readings and fan speed. Doubles as Warning.
- **System Indigo — Disk** (`#6155F5` / `#6D7CFF`): capacity and free space.
- **System Brown — Developer** (`#AC7F5E` / `#B78A66`): containers, listening ports, runtimes.
- **System Red — Alerts** (`#FF383C` / `#FF4245`): the Alerts section and Critical health. Nothing else may use it.

### Neutral

Alpha-based, so they compose correctly over any surface in either appearance.

- **Ink** (black/white @ 85%): every figure and heading.
- **Ink Secondary** (black @ 50% / white @ 55%): labels, captions, units — the words beside a number, never the number.
- **Ink Tertiary** (black @ 26% / white @ 25%): disabled and decorative glyphs only.
- **Hairline** (black/white @ 10%, drawn at 60% opacity, 0.5pt): the only border in the system.
- **Surface** (window `#FFFFFF` / `#1E1E1E`; cards one step in from it): tonal layering, no shadow.

### Named Rules

**The One Job Rule.** A tint means exactly one metric family. If a chart needs several parts of one family (the memory ring, per-core lines), step the *same* tint with `MetricStyle.shade(_:of:)` — never reach for a second hue. Rainbow series are forbidden.

**The Status Reserve Rule.** Green, orange and red carry Health Level and nothing else. A metric is never coloured by how alarming its value is; it is coloured by what it measures. The badge is the only thing allowed to change colour with state.

**The Away-From-Background Rule.** Stepped shades must walk *away* from the surface they sit on: darker on light, lighter on dark. Every step holds ≥3:1 against its own background (WCAG 1.4.11), asserted by tests. The OKLCH lightness bands are 0.66→0.28 in light and 0.56→0.92 in dark; five steps of one hue cannot also reach 3:1 against each other, so band edges — ring insets, stacked-chart hairlines — carry the separation instead.

## 3. Typography

**Display / Body / Label Font:** SF Pro (`-apple-system`), at macOS's stock text styles. No second family.

**Character:** The system typeface, used the way the OS uses it. Weight and size carry the whole hierarchy; there is no display face, no pairing, no letter-spacing tricks. Every changing figure is set with `monospacedDigit()` so numbers do not jitter as they update — in an instrument that redraws every second, stable digits are a correctness feature, not a refinement.

### Hierarchy

- **Display** (Large Title, bold, 26pt): the page title each section draws for itself. The window's own title bar is hidden, so this is the only place a page is named.
- **Headline** (Title, semibold, 22pt): the headline figure on a summary card — "12%", "41°C".
- **Title** (Title 3, semibold, 15pt): section headings, with the hardware name trailing in Ink Secondary.
- **Body** (Body/Headline, 13pt): card titles and table content.
- **Label** (Callout, 12pt): statistics-rail rows, legends, key/value pairs. The dominant size on a dense page.
- **Caption** (Caption, 10pt): units, the "vs 5m avg" qualifier, chart footnotes.

### Named Rules

**The Sentence Case Rule.** Multi-word labels are sentence case — "Current frequency", "Memory in use", "Swap used" — matching the rest of the app ("Cycle count", "Maximum capacity"). Acronyms keep their case, and names the machine supplies keep theirs ("Cores (Super)" is the kernel's word, not ours).

**The Stable Digit Rule.** Any number that updates carries `monospacedDigit()`. A figure that reflows while you read it is a bug.

## 4. Elevation

**There are no shadows in Mac Pulse.** Depth is tonal: the window surface, a card one step in from it, and a 0.5pt hairline at 60% opacity to close the edge. Nothing lifts, nothing floats, nothing casts. A flat instrument face reads as calibrated; a lifted card reads as an advertisement.

Grouping is the job of the card, not of depth. Where two things must be told apart inside one surface — bands in a stacked chart, sectors in the ring — they are separated by a drawn edge in the surface colour, not by elevation.

### Named Rules

**The Flat Face Rule.** No `shadow`, no blur, no glass, no gradient fills except the single subtle area gradient under a solo sparkline. If a surface needs to stand out, it gets the hairline and the tonal step — that is the whole vocabulary.

## 5. Components

**Character: quiet instruments in native chrome.** Surfaces recede, the reading is the only bright thing, and every control is stock so the system supplies hover, focus and keyboard behaviour.

### Cards / Containers
- **Corner Style:** continuous 12px (`cardBackground()`), the one card shape in the app.
- **Background:** one tonal step in from the window surface.
- **Border:** 0.5pt hairline at 60% opacity. No shadow — see Elevation.
- **Internal Padding:** 16px; 24px around the page; 20px between sections.
- **Nesting:** forbidden. A card never contains another card; inner grouping uses plain stacks.

### Metric cards
The summary row. Tinted SF Symbol and title, optional Health badge trailing, then the headline figure with its trend delta beside a sparkline, and a caption below at full card width. They wrap two-up rather than compress: `LazyVGrid(.adaptive(minimum: 240))`, so at the 980pt window minimum the titles stay whole instead of truncating.

### Statistics rail
The rail beside a chart (230pt, 7pt row rhythm, label left in Ink Secondary, value right in monospaced digits). **A row whose value is nil is omitted entirely** — this is the visual expression of the product's first principle. Rail height therefore varies by machine, and that is correct.

### Charts
- Live series plot against "seconds ago"; stored ranges plot real timestamps with a min–max band.
- A solo series gets a subtle area gradient beneath it; multiple series are lines only.
- Many-series charts downsample to a mark budget, keeping bucket peaks so spikes survive.
- Before two samples exist, the grid stays visible and a single line of Ink Secondary text names what is coming ("CPU usage appears within a few seconds") — a skeleton, never a spinner.
- Charts expose one accessibility element announcing the latest value per series, not one element per mark.

### Health badge
Capsule, 8×2px padding, caption weight medium, text in the Health tint over the same tint at 15%. The only component that changes colour with state.

### Buttons
- **Prominent:** used once per page at most, for the page's single action (Run Diagnostics).
- **Small bordered:** the standard for navigating elsewhere — "View History", "View All". Stock `.controlSize(.small)`.
- **Never** a bare `.plain` button styled as a row: it has no hover and no focus ring.

### Pickers
Segmented, labels hidden, `fixedSize()`. Range (Live…30d) sits in the page header; mode pickers sit on their section header.

### Named Rules

**The Stock Control Rule.** If AppKit or SwiftUI ships the affordance, use it. A custom row that merely looks clickable is a regression — it loses hover, focus ring and keyboard reachability that the stock control gives for free.

**The Nil Row Rule.** Components render `String?` and drop nil rows. Nothing displays an em dash for a value the machine cannot report.

## 6. Do's and Don'ts

### Do:
- **Do** take tints from `MetricStyle` and step them with `shade(_:of:)`. One tint per family, always.
- **Do** keep status colour for Health Level alone — green/orange/red mean a state, never a category.
- **Do** set `monospacedDigit()` on every figure that updates.
- **Do** hide a row whose value this Mac cannot report, and print the reason nowhere — absence is the honest signal.
- **Do** write multi-word labels in sentence case, and keep the machine's own words ("Cores (Super)") exactly as the machine gives them.
- **Do** verify both appearances on screen. A ramp that reads well on dark can walk into a white background.
- **Do** use stock controls so hover, focus and keyboard come from the system.
- **Do** keep every meaningful graphic at ≥3:1 against its background, and print the value beside it so nothing is carried by colour alone.

### Don't:
- **Don't** ship **gamer/RGB monitoring skin** cues: neon gradients, animated gauges, glowing rings, carbon-fibre texture. Telemetry is evidence, not spectacle.
- **Don't** fall back to **Activity Monitor's blandness** — unstyled tables with no hierarchy answer nothing at a glance.
- **Don't** build the **SaaS dashboard template**: hero metric tiles with gradient accents, identical card grids, decorative illustrations, purple-blue gradients.
- **Don't** go **alarmist red-everywhere**. Warning colour for routine variation trains the user to ignore the one that matters.
- **Don't** add shadows, blur or glass. If it looks lifted, it is wrong — the face is flat.
- **Don't** nest a card inside a card.
- **Don't** introduce a second hue to separate parts of one metric. Step the tint, and draw the edge.
- **Don't** show a dash, a zero, or an estimate where a real reading is unavailable.
- **Don't** animate live data. Motion must convey state; a crossfade on a figure that updates every second fights the reading. The app currently ships no motion, so there is nothing to reduce — anything added later must honour Reduce Motion.

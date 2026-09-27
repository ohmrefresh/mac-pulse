# Product

## Register

product

## Users

Three personas from the PRD (§4), all technical, all arriving mid-task rather than browsing:

- **P1 — Software developer.** Wants to know why the Mac slowed down after starting Docker and an IDE. Cares about IDE and container CPU, Node/Java processes, memory pressure, localhost services.
- **P2 — DevOps / SRE / platform engineer.** Watching connectivity as much as the machine: latency, packet loss, DNS health, VPN state, and when an incident started.
- **P3 — Power user.** Battery drain, temperature, storage, bandwidth. Less fluent in the vocabulary, same need for a straight answer.

Context of use: a glance at the menu bar during other work, or the dashboard opened *because something already feels wrong*. Nobody opens a system monitor for pleasure — they open it with a question.

## Product Purpose

Mac Pulse answers one question the built-in tools do not: **what is happening to this Mac, when did it start, and what is likely causing it.** Activity Monitor shows the present instant; Mac Pulse keeps history, marks when things changed, and offers deterministic diagnostics.

Success is a user going from "my Mac feels wrong" to a specific, checkable cause — without leaving the menu bar if the answer is simple.

Delivery is a single unsandboxed process distributed with Developer ID (ADR 0001): menu-bar item, popover, dashboard, history, alerts, diagnostics. No daemon, no cloud, no account.

## Brand Personality

**Precise, calm, honest.** An instrument, not a commentator.

- **Precise** — "4.61 GHz", not "fast". Real units, real figures, the user's own locale.
- **Calm** — colour appears when health changes, not to decorate. A monitor that raises its voice constantly gets ignored, then uninstalled.
- **Honest** — a value this Mac cannot report is *absent*, never dashed, never estimated. Diagnostics hedge causes and state observations flatly.

Voice: short, factual, sentence case. Name things the way macOS names them ("Memory Used", "Cached Files") so the numbers can be checked against Activity Monitor.

## Anti-references

- **Gamer / RGB monitoring skins.** Neon gradients, animated gauges, glowing rings. Treats telemetry as spectacle; Mac Pulse treats it as evidence.
- **Activity Monitor's blandness.** Unstyled tables with no hierarchy. Functional, but gives no at-a-glance answer — the exact gap this product exists to fill.
- **SaaS dashboard template.** Hero metric tiles with gradient accents, identical card grids, decorative illustrations, purple-blue gradients.
- **Alarmist red-everywhere.** Warning colours and badges for routine variation. Crying wolf destroys the one thing a monitor sells: trust that a red state means something.

## Design Principles

1. **Never show a value we don't measure.** If this Mac cannot report a figure, its row is hidden — not dashed, not inferred, not borrowed from a similar machine. Applies hardest to the private-API readings (ADR 0002, ADR 0003), which are all-optional by construction.
2. **Answer "what changed and when", not just "what is now".** History, the timeline, and the trend deltas exist because the instant reading is rarely the question. A number without its recent past is trivia.
3. **Colour is a health signal, not decoration.** Status colour is reserved for Health Level. Metric tints identify a family; they never imply alarm. One tint per metric, stepped when a chart needs parts.
4. **Menu-bar first.** The app must stay fully useful with no window open, and cost nothing when hidden — every expensive reading is gated on something actually being visible.
5. **Hedge causes, state observations.** Diagnostics separate what was measured from what might explain it, and the type system makes an unhedged cause unexpressible. The product may be confident about facts and never about blame.

## Accessibility & Inclusion

- **WCAG AA, VoiceOver-complete.** Body text ≥ 4.5:1; non-text and chart graphics ≥ 3:1. The shade-ramp floors and the Health Level vocabulary (badge ink at 4.5:1, dots and glyphs at 3:1, both appearances) are asserted by tests, so a palette change that drops below them fails the build rather than shipping.
- **Charts are summarised, not enumerated.** Each chart is one labelled element announcing its latest value per series; decorative sparklines are hidden from the accessibility tree entirely.
- **Every control labelled and keyboard-reachable**, using standard AppKit/SwiftUI affordances so hover, focus and keyboard behaviour come from the system rather than being reimplemented.
- **Both appearances are first-class.** Light and Dark are verified on screen, and colour ramps walk away from whichever background they sit on.
- **Information is never carried by colour alone** — every chart band and ring slice has its value printed beside it, and every Health Level state carries a glyph (check, triangle, octagon) as well as a tint, so a severity row reads in greyscale.
- **Motion:** the app ships one animation, the sensor table's disclosure, and it honours Reduce Motion. Any motion added later does the same, and must convey state, not decorate.

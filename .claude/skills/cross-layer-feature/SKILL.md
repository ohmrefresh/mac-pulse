---
name: cross-layer-feature
description: Implement an approved Mac Pulse plan that spans the package and the app (PulseCore/Collectors/Engine → App) with the project agents package-engineer, app-engineer and invariant-reviewer. Use when the user says "implement this plan", "build this feature across layers", "cross-layer feature", or after a grill-with-docs / plan-mode session is approved.
argument-hint: <path to approved plan file>
---

# Cross-layer feature

This is the hand-driven version. For a hands-off run, use the `cross-layer-feature` workflow with the plan path as `args`; it runs the same stages and returns a summary.

## 0. Preconditions
- An approved plan exists, from `/grill-with-docs` or plan mode. Without one, run `/grill-with-docs` first. The user's decisions come from that grilling, not from you.
- Record it: `hindsight_capture_initiative(title, summary)`. Call it again, with `relates_to_page_id`, if the scope changes mid-work.

## 1. Package
Spawn the `package-engineer` agent (named, so it can be messaged later) with:
- the plan path and the sections it owns (PulseCore / PulseCollectors / PulseStore / PulseEngine);
- an instruction to keep deprecated shims for any App-facing API change.

Wait for its report: API signatures, files, test lines, and App call sites that break.

Chart-only or other App-internal groundwork that doesn't depend on the new API may run in parallel as an `app-engineer`. The paths the two agents edit must not overlap.

## 2. App
Spawn `app-engineer` with the plan path, its sections, and the package agent's API report pasted verbatim. The report includes the call sites it must move off shims. Wait for the files, the test summary and the screenshot paths. Look at the screenshots yourself.

## 3. Review
Spawn `invariant-reviewer` on the uncommitted diff, naming the plan and any new ADR. Then:
- **CONFIRMED** 🔴 and 🟡 findings: route each to the engineer that owns the file (package vs App), with `file:line` and the fix.
- **PLAUSIBLE** findings: check them yourself first, or ask the reviewer to settle one with a test.
- **Accepted trade-offs** (e.g. "don't block quit"): don't fix them; list them in the final report.

## 4. Remove shims
Once the App has moved off the shims, tell `package-engineer` to delete them, then run `swift test` plus the App build.

## 5. Gate and docs
- `cd Packages/MacPulseKit && swift test` and `xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -destination "platform=macOS" -derivedDataPath .build/xcode test`: both green, and you ran them yourself.
- CONTEXT.md: add any new domain term (glossary only).
- CLAUDE.md: add a one-line invariant if a new rule appeared (a gate, a cadence, a persisted meaning).
- ADR: only if the decision is hard to reverse, surprising, and a real trade-off.
- Run `graphify update .`.

## 6. Stop
Don't commit or push. Report to the user:
- what they can now do;
- deviations and accepted trade-offs;
- the verification actually run (and what wasn't, e.g. the soak test);
- files touched.

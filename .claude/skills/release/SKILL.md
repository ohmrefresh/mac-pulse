---
name: release
description: Prepare a Mac Pulse release locally. Bump MARKETING_VERSION, write the CHANGELOG section, run the tests and the soak gate, then commit and tag. Stops before any push.
argument-hint: X.Y.Z
disable-model-invocation: true
---

# Release X.Y.Z

Prepares everything the CI `release` job checks (see CLAUDE.md → Releasing), then stops. **Never push.** Pushing the tag publishes a GitHub Release; the user does that.

The version is `$ARGUMENTS`. If it is empty, ask for it.

## 1. Preconditions: stop on any failure
- `git status --porcelain` is empty, and the branch is `main` (`git branch --show-current`). If not, stop and tell the user. Never stash or switch branches for them.
- `$ARGUMENTS` matches `^\d+\.\d+\.\d+$`.
- It is greater than the current `MARKETING_VERSION` in `project.yml` (semantic comparison).
- No tag `v$ARGUMENTS` exists yet (`git tag -l`).

## 2. Bump
In `project.yml`, set `MARKETING_VERSION: "$ARGUMENTS"`. Don't change the build number; it is `git rev-list --count HEAD`.

## 3. CHANGELOG
- Last tag: `git describe --tags --abbrev=0`. Gather `git log <lastTag>..HEAD --no-merges --format='%s%n%b'`.
- Draft `## [$ARGUMENTS] — <today YYYY-MM-DD>` above the previous section in `CHANGELOG.md`, following the file's existing style:
  - Keep a Changelog groups (`### Added`, `### Changed`, `### Fixed`);
  - user-facing sentences in CONTEXT.md vocabulary, not commit subjects;
  - no internal refactors unless users would notice them.
- If the build is still ad-hoc signed (no signing secrets), keep the first-launch note the way 0.1.1 does.
- Show the draft to the user and wait for approval or edits before continuing.

## 4. Gate: stop on any failure and report it
- `cd Packages/MacPulseKit && swift test`
- `xcodegen generate && xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -destination "platform=macOS" -derivedDataPath .build/xcode test`
- `DURATION=300 scripts/soak.sh`: every PRD §18 budget must pass (idle CPU < 1%, footprint < 150 MB). A miss blocks the release, and you don't loosen a budget to pass.

## 5. Commit and tag (local only)
- `git add project.yml CHANGELOG.md`, then `git commit -m "Release $ARGUMENTS"`
- `git tag -a v$ARGUMENTS -m "Mac Pulse $ARGUMENTS"`

## 6. Hand off
Print, but do not run:

```sh
git push origin main && git push origin v$ARGUMENTS
```

Then tell the user:
- the CI `release` job runs after `test`, and fails if the tag and `MARKETING_VERSION` differ or the CHANGELOG section is missing;
- 0.x versions publish as pre-releases;
- it signs only with the `DEVELOPER_ID_*` secrets and notarizes only with the `NOTARY_*` secrets; otherwise the DMG is ad-hoc signed.

To undo before pushing: `git tag -d v$ARGUMENTS && git reset --hard HEAD~1`. Only run that if the user asks; it is destructive.

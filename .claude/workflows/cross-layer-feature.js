export const meta = {
  name: 'cross-layer-feature',
  description: 'Implement an approved Mac Pulse plan: package → app → invariant review → one fix round → test gate. Never commits.',
  whenToUse: 'After /grill-with-docs or plan mode produced an approved plan that spans Packages/MacPulseKit and App/. Pass the plan file path as args.',
  phases: [
    { title: 'Package', detail: 'package-engineer implements PulseCore/Collectors/Store/Engine test-first' },
    { title: 'App', detail: 'app-engineer wires App/ to the new API, builds, screenshots' },
    { title: 'Review', detail: 'invariant-reviewer checks the diff against CLAUDE.md' },
    { title: 'Fix', detail: 'one fix agent per owning layer for confirmed findings; shim removal' },
    { title: 'Gate', detail: 'swift test + xcodebuild test' },
  ],
}

const plan = typeof args === 'string' ? args.trim() : ''
if (!plan) throw new Error('Pass the approved plan file path as args, e.g. "/Users/…/.claude/plans/x.md".')

const PACKAGE_RESULT = {
  type: 'object',
  properties: {
    api: { type: 'string', description: 'Exact new/changed public API signatures' },
    files: { type: 'array', items: { type: 'string' } },
    tests: { type: 'string', description: 'swift test summary lines, verbatim' },
    appBreaks: { type: 'array', items: { type: 'string' }, description: 'App file:line call sites to migrate, incl. deprecated shims' },
    shimsKept: { type: 'boolean', description: 'true if deprecated shims were left for the App' },
    deviations: { type: 'string' },
  },
  required: ['api', 'files', 'tests', 'appBreaks', 'shimsKept'],
}

const APP_RESULT = {
  type: 'object',
  properties: {
    files: { type: 'array', items: { type: 'string' } },
    tests: { type: 'string', description: 'xcodebuild test summary, verbatim' },
    screenshots: { type: 'array', items: { type: 'string' } },
    deviations: { type: 'string' },
  },
  required: ['files', 'tests', 'screenshots'],
}

const REVIEW_RESULT = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['bug', 'risk', 'nit'] },
          verdict: { type: 'string', enum: ['CONFIRMED', 'PLAUSIBLE'] },
          owner: { type: 'string', enum: ['package', 'app'], description: 'package = Packages/MacPulseKit, app = App/ or project.yml' },
          summary: { type: 'string' },
          fix: { type: 'string' },
        },
        required: ['file', 'severity', 'verdict', 'owner', 'summary', 'fix'],
      },
    },
    verifiedOk: { type: 'array', items: { type: 'string' } },
  },
  required: ['findings'],
}

const FIX_RESULT = {
  type: 'object',
  properties: {
    fixed: { type: 'array', items: { type: 'string' } },
    skipped: { type: 'array', items: { type: 'string' }, description: 'finding + reason it was not fixed' },
    tests: { type: 'string' },
  },
  required: ['fixed', 'skipped', 'tests'],
}

const GATE_RESULT = {
  type: 'object',
  properties: {
    packagePassed: { type: 'boolean' },
    appPassed: { type: 'boolean' },
    packageSummary: { type: 'string' },
    appSummary: { type: 'string' },
    failures: { type: 'string' },
  },
  required: ['packagePassed', 'appPassed', 'packageSummary', 'appSummary'],
}

const NO_COMMIT = 'Do not commit or push.'

phase('Package')
const pkg = await agent(
  `Implement the package part of the approved plan at ${plan}: every PulseCore / PulseCollectors / PulseStore / PulseEngine change it lists. ` +
  `Keep deprecated shims for any API the App uses. ${NO_COMMIT} Return your report as structured output.`,
  { label: 'package', phase: 'Package', agentType: 'package-engineer', schema: PACKAGE_RESULT })
if (!pkg) throw new Error('Package stage produced no result; stopping before the App stage.')
log(`Package: ${pkg.files.length} files; ${pkg.appBreaks.length} App call sites to migrate`)

phase('App')
const app = await agent(
  `Implement the App part of the approved plan at ${plan}. The package API is ready; its engineer reported:\n\n` +
  `API:\n${pkg.api}\n\nApp call sites to migrate (move off every deprecated shim):\n${pkg.appBreaks.join('\n') || '(none)'}\n\n` +
  `Package deviations: ${pkg.deviations || 'none'}\n\n${NO_COMMIT} Return your report as structured output.`,
  { label: 'app', phase: 'App', agentType: 'app-engineer', schema: APP_RESULT })
if (!app) throw new Error('App stage produced no result; stopping before review.')

phase('Review')
const review = await agent(
  `Review the uncommitted diff implementing the plan at ${plan}. Assign each finding an owner: "package" for Packages/MacPulseKit, "app" for App/ or project.yml. ` +
  `Return structured output.`,
  { label: 'review', phase: 'Review', agentType: 'invariant-reviewer', schema: REVIEW_RESULT })
const findings = review ? review.findings : []
const actionable = findings.filter(f => f.verdict === 'CONFIRMED' && f.severity !== 'nit')
const deferred = findings.filter(f => !actionable.includes(f))
if (!review) log('Review agent returned nothing; skipping the fix round. Review the diff by hand.')
if (deferred.length) log(`${deferred.length} PLAUSIBLE or nit findings left for you to judge (not auto-fixed)`)

phase('Fix')
const describe = f => `- ${f.file}${f.line ? ':' + f.line : ''} [${f.severity}] ${f.summary} → ${f.fix}`
const byOwner = { package: actionable.filter(f => f.owner === 'package'), app: actionable.filter(f => f.owner === 'app') }
const fixes = await parallel([
  byOwner.package.length ? () => agent(
    `Fix these confirmed review findings, test-first, for the plan at ${plan}:\n${byOwner.package.map(describe).join('\n')}\n` +
    `If a finding is wrong, skip it and say why. ${NO_COMMIT}`,
    { label: 'fix:package', phase: 'Fix', agentType: 'package-engineer', schema: FIX_RESULT }) : null,
  byOwner.app.length ? () => agent(
    `Fix these confirmed review findings for the plan at ${plan}:\n${byOwner.app.map(describe).join('\n')}\n` +
    `If a finding is wrong, skip it and say why. ${NO_COMMIT}`,
    { label: 'fix:app', phase: 'Fix', agentType: 'app-engineer', schema: FIX_RESULT }) : null,
].filter(Boolean))

// Package and App fixes touch disjoint paths, so they ran in parallel; shims go only after the App fix settled.
let shims = null
if (pkg.shimsKept) {
  shims = await agent(
    `The App no longer uses the deprecated shims you kept for the plan at ${plan}. Remove them, update any tests that used them, ` +
    `run swift test and the App build (xcodebuild -project MacPulse.xcodeproj -scheme MacPulse -destination "platform=macOS" -derivedDataPath .build/xcode build). ${NO_COMMIT}`,
    { label: 'remove-shims', phase: 'Fix', agentType: 'package-engineer', schema: FIX_RESULT })
}

phase('Gate')
const gate = await agent(
  'Run both Mac Pulse test suites and report the results; change no files. ' +
  '(1) cd Packages/MacPulseKit && swift test. (2) From the repo root: xcodegen generate && xcodebuild -project MacPulse.xcodeproj -scheme MacPulse ' +
  '-destination "platform=macOS" -derivedDataPath .build/xcode test. Paste the summary lines verbatim. Put any failing test names and errors in failures.',
  { label: 'gate', phase: 'Gate', effort: 'low', schema: GATE_RESULT })

return {
  plan,
  package: pkg,
  app,
  review: { actionable, deferred, verifiedOk: review ? review.verifiedOk : [] },
  fixes: fixes.filter(Boolean),
  shims,
  gate,
  next: gate && gate.packagePassed && gate.appPassed
    ? 'Gate green. Review the diff, update CONTEXT.md/CLAUDE.md/ADR if the plan calls for it, run graphify update ., then commit yourself.'
    : 'Gate failed or missing: inspect gate.failures before anything else.',
}

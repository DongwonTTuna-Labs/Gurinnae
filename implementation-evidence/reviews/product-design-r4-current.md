# Product Design Independent Freeze Review

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE

REVIEWED_AT_UTC: 2026-07-20

## Scope and source

Fresh review of the current source tree against the pinned v13 information
architecture, responsive, WCAG/KWCAG, state/error UX, and visual consistency
contracts. The sorted SHA-256 manifest for all 75 files under
`packages/ui/src` is:

`bd70fe85cdd47c9969879be4462798a31e501822658012bdc9bbcf0b660cd01a`

CAS-010 and CAS-011 were traced through the review-console screen contracts,
`loadScreen()`'s `projectFetchedData()` call, the typed CAS view-models, and
`AgentAnalysisProjection.svelte`.

## Blocking findings

### 1. Current source visual evidence is not green

After rebuilding `@gurine/review-console` from the current source, the
unchanged CAS snapshots fail in all six cases:

- CAS-010 wide: expected 1440×1933, received 1440×2379
- CAS-010 medium: expected 900×2131, received 900×2628
- CAS-010 compact: expected 360×2749, received 360×3368
- CAS-011 wide: expected 1440×4862, received 1440×4484
- CAS-011 medium: expected 900×5420, received 900×4726
- CAS-011 compact: expected 360×5946, received 360×5682

`bunx playwright test tests/e2e/visual-routes.spec.ts --grep
'CAS-010|CAS-011'` therefore reports `6 failed`. These are material layout and
information-density changes, not a passing visual gate. Snapshots must be
regenerated only after the final source is frozen, then the six tests must pass
against that unchanged source.

### 2. CAS-010/011 API → projection → render is not exercised end to end

The screen contracts correctly declare `listCaseAgentRuns` and `getAgentRun`,
and the typed projection/view-model unit tests cover valid `analysis-vm.cas-010.v2`
and `analysis-vm.cas-011.v2` envelopes. However,
`tests/e2e/support/mock-api-reads.ts` has no handlers for either internal query
path; both fall through to the generic read response (`items: []`, filters,
cursor) with no `analysisVm`. Consequently the CAS visual routes render the
empty/unknown path and do not prove that an API envelope reaches the typed
projection, accessible metric table, or CAS-011 provenance graph in the DOM.
Add a deterministic authority-shaped API fixture/route and an authenticated
browser assertion for the rendered metric table and provenance rows. Keep the
negative unknown/error path as a separate test.

## Passing checks (insufficient for a verdict)

- `bun run --filter '@gurine/ui' check`: PASS, 0 errors / 0 warnings.
- `bun run --filter '@gurine/ui' test`: PASS, 35 tests.
- Public-web, review-console, and response-portal checks: PASS, each 0
  errors / 0 warnings.
- `accessibility-responsive.spec.ts --grep ACCESSIBILITY_RESPONSIVE`: PASS,
  8/8 tests.
- `python3 -B scripts/validation/design_freeze.py --mode lint`: PASS,
  `STRUCTURE_LINT: PASS`, zero problems.
- `git diff --check`: PASS.

The passing unit/accessibility checks do not waive the failed current visual
gate or the missing authenticated CAS API-to-render evidence. Re-review is
required after both blockers are fixed and the unchanged-source evidence is
rerun.

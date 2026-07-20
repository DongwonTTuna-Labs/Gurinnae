# Product Design Re-review — CAS-010/CAS-011 projection integration

DESIGN_VERDICT: CHANGES_REQUIRED

ROLE: PRODUCT_DESIGN / INFORMATION_ARCHITECTURE / ACCESSIBILITY_RESPONSIVE
REVIEWED_AT_UTC: 2026-07-19
AUTHORITY_ZIP_SHA256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

## Review boundary

This is an independent re-review of the current worktree after the
`analysis-vm.cas-010.v2` and `analysis-vm.cas-011.v2` producer/view-model
changes. The current source tree is not clean and its final source digest is
therefore intentionally not asserted here. The authority design axis is
`DESIGN.md`; the v13 authority screen contract remains the source of section
order and responsive/accessibility requirements.

## Findings

### P1-DESIGN-CAS-001 — typed CAS projections do not reach the screen renderer

The new `apps/review-console/src/lib/view-models/cas-010.ts` and `cas-011.ts`
functions are imported only by `cas.test.ts`. They are not used by
`packages/ui/src/screen-projection-specialized.ts`, `ScreenSection.svelte`, or
any CAS route component.

The generated bindings still resolve the old paths (`$.runs`, `$.suggestions`,
`$.budget`, and `$.identity`/`$.inputs`/`$.output`/`$.citations`). The actual
server responses are:

* `listCaseAgentRuns`: `{items, analysisVm}`; `analysisVm` is the closed CAS-010
  projection containing visualization data, not top-level `runs`/`budget`.
* `getAgentRun`: `{id, status, data: { ..., analysisVm } , links}`; the CAS-011
  projection is nested at `data.analysisVm`.

Consequently the normal `projectFetchedData` path yields UNKNOWN/empty CAS
sections and the visualization/provenance graph is not rendered. This breaks
the ten-second contract (answer, uncertainty, evidence, and next action) and
means the accessible table alternative and provenance rows cannot be reached by
keyboard or screen reader. A browser test can pass on blocked/unauthenticated
fixtures while this regression remains hidden; a data-backed CAS-010/011
journey is required.

Required root-cause fix: make the server-owned projection envelope and the UI
mapper agree on one response path, then bind the typed CAS-010 visualization and
CAS-011 visualization/provenance rows into explicit screen sections. Do not
fall back to raw JSON or infer fields from DTOs. Add a data-backed responsive
and accessibility assertion that checks the metric's narrative/table
alternative and at least one provenance row are visible in the DOM at 320px,
768px/200% zoom, and wide layout.

Direct projection probe (Bun, current source) confirms the failure: feeding a
valid `{items, analysisVm}` CAS-010 response leaves `runs`, `filters`,
`suggestions`, and `budget` fields `known:false`; feeding a valid
`{data:{analysisVm}}` CAS-011 response leaves `identity`, `inputs`, `model`,
`output`, `citations`, `safety`, `decisions`, and `cost` fields `known:false`
(only the top-level status is known). This is a deterministic projection
failure, not an unavailable/empty dataset.

### P1-DESIGN-CAS-002 — mapper contract cannot represent the published CAS-010 envelope

`toCas010ViewModel` requires `caseId`, `screenState`, and `runs` from
`analysisVm`, but `cas010_projection` publishes a deliberately reduced
projection containing only `schemaVersion`, `screenId`, `visualizations`, and
`viewModelSha256`. The mapper therefore returns empty identity/state/run values
even when the server returns a valid projection. This is a contract mismatch,
not an empty business result, and must remain an explicit UNKNOWN/blocked state
until the typed envelope is repaired.

Required root-cause fix: either publish the full authority-required CAS-010
typed envelope and validate it, or narrow the mapper type to the reduced
projection and provide the missing object/state/next-action fields through the
screen's existing typed projection. The chosen shape must be reflected in the
OpenAPI/generated types and acceptance fixture; no synthetic defaults.

### P1-DESIGN-CAS-003 — CAS-011 response unwrapping is incorrect

`toCas011ViewModel` searches `getAgentRun.analysisVm`; the OpenAPI contract
places it under `getAgentRun.data.analysisVm`. With an otherwise valid response
the mapper returns `null`, so the accessible provenance graph is silently
unavailable. The adapter must unwrap the generated `data` envelope explicitly
and preserve the server-provided digest fields.

## Positive checks

* `bun run check` in `apps/review-console`: PASS (0 errors, 0 warnings).
* `bun run test` in `apps/review-console`: PASS (2 files, 3 tests), including
  the new CAS mapper unit tests. These tests only exercise synthetic mapper
  input and do not prove route integration.
* `bun run check` in `packages/ui`: PASS (0 errors, 0 warnings).
* Existing CAS runtime traces retain one heading, declared section order, and
  focus/error targets, but both traces are blocked/unauthenticated and do not
  prove a data-backed visualization or graph render.

## Verdict

The shared layout still has the required compact/medium/wide and focus/error
infrastructure, but the current CAS implementation does not expose its typed
visualization/provenance evidence to users. The above P1 findings must be
closed and re-tested against a source-bound, data-backed browser trace before
an independent design `LGTM_NO_BLOCKING` can be issued.

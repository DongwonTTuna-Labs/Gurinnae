# Final Component Design Manual

상태: **FINAL**

총 58개 component contract를 정의한다.

## `AccessManagementPanel`

사용자·역할·capability·access review를 안전하게 관리한다.

- Category: `access`
- Surfaces: internal
- Variants: user-detail, role-definition, access-review
- States: loading, ready, no-access, conflict, reauth-required, receipt

### Anatomy

- identity summary
- current roles
- effective capabilities
- expiry
- risk notice
- change reason
- reauth gate
- audit receipt

### Rules

- Role visibility is not authorization.
- High-risk role changes require step-up and reason.
- Break-glass is visually distinct and time-bounded.

### Accessibility

- role matrix has row and column headers
- changes summarized before submit
- focus moves to receipt

## `AgentSuggestionPanel`

AI 제안을 근거·비용·한계와 함께 보조 정보로 표시한다.

- Category: `ai-assist`
- Surfaces: internal
- Variants: summary, detail, diff
- States: queued, running, completed, failed, budget-blocked, stale

### Anatomy

- agent type
- objective
- provider/model
- evidence scope
- suggestion
- citations
- unknowns
- cost
- accept/reject reason

### Rules

- Never precedes deterministic evidence.
- Accepting suggestion records provenance; it does not auto-mutate publication.
- No confidence percentage presented as truth likelihood.

### Accessibility

- AI label is textual
- citations keyboard reachable
- streaming does not steal focus

## `AppHeader`

Surface identity, primary navigation and utilities.

- Category: `navigation`
- Surfaces: public, internal, response
- Variants: public, internal, response
- States: default, incident, compact

### Anatomy

- label
- content
- state
- actions

### Rules

- Never share authenticated session UI between surfaces.

### Accessibility

- skip link precedes header
- navigation has unique aria-label
- menu returns focus

## `AssignmentControl`

Owner and handoff.

- Category: `workflow`
- Surfaces: internal
- Variants: single, team
- States: assigned, unassigned, pending

### Anatomy

- label
- content
- state
- actions

### Rules

- Reason/history retained.

### Accessibility

- combobox/list semantics

## `AuditEventList`

Immutable event browsing.

- Category: `history`
- Surfaces: internal
- Variants: case, global, high-impact
- States: normal, restricted, integrity-gap

### Anatomy

- label
- content
- state
- actions

### Rules

- No edit/delete controls.

### Accessibility

- table/list toggle

## `Breadcrumbs`

Object hierarchy and context.

- Category: `navigation`
- Surfaces: public, internal
- Variants: standard, compact
- States: default, overflow

### Anatomy

- label
- content
- state
- actions

### Rules

- Not a browser back replacement.

### Accessibility

- nav label
- current item not linked

## `CaseTaskRail`

Grouped case tasks and blockers.

- Category: `workflow`
- Surfaces: internal
- Variants: wide, compact-selector
- States: default, blocked, collapsed

### Anatomy

- label
- content
- state
- actions

### Rules

- Groups are Overview, Investigation, Authoring, Review & Publication, Records.

### Accessibility

- nav label and current item

## `CheckAnswers`

Review structured answers before submit.

- Category: `form`
- Surfaces: response, public
- Variants: response, correction, subscription
- States: complete, missing

### Anatomy

- label
- content
- state
- actions

### Rules

- Final submit consequence is explicit.

### Accessibility

- change links identify field

## `ClaimCard`

Claim type, text, citations, limitations and response.

- Category: `evidence`
- Surfaces: public, internal
- Variants: public, authoring, review
- States: draft, valid, blocked, corrected

### Anatomy

- label
- content
- state
- actions

### Rules

- Factual claim requires evidence.

### Accessibility

- citation controls descriptive

## `ClaimWorkbench`

claim을 작성하고 evidence·response·limitation을 연결한다.

- Category: `editorial`
- Surfaces: internal
- Variants: authoring, review, read-only
- States: draft, saving, valid, blocked, conflict, corrected

### Anatomy

- claim type
- text editor
- evidence citations
- response links
- limitations
- validation results
- version
- save status

### Rules

- Factual claims require evidence.
- Prohibited language is blocked, not merely warned.
- Domain entity is never edited through generic JSON.

### Accessibility

- validation summary links to fields
- citation controls have descriptive labels
- conflict preserves draft

## `ComparisonTable`

Comparable records, inclusion/exclusion and units.

- Category: `data`
- Surfaces: public, internal
- Variants: public, dense, downloadable
- States: complete, partial, empty

### Anatomy

- label
- content
- state
- actions

### Rules

- Comparison compatibility is visible.

### Accessibility

- caption
- header scope
- horizontal scroll region

## `ComparisonWorkbench`

target와 비교군·제외군·계산을 동일 문맥에서 설명한다.

- Category: `data`
- Surfaces: public, internal
- Variants: public-read, investigation, reproducibility
- States: ready, insufficient-cohort, blocked, partial, stale, error

### Anatomy

- comparison statement
- target row
- benchmark summary
- distribution
- included cohort
- excluded cohort
- formula
- limitations

### Rules

- No comparison without unit/bundle/VAT/date compatibility.
- No standalone multiple without benchmark and denominator.
- Excluded records remain inspectable.

### Accessibility

- chart has equivalent table
- included/excluded reason announced
- unit and VAT basis present in text

## `ConflictBanner`

Version conflict and draft-preserving resolution.

- Category: `feedback`
- Surfaces: internal, response
- Variants: case, draft
- States: active, resolved

### Anatomy

- label
- content
- state
- actions

### Rules

- No silent overwrite.

### Accessibility

- focusable summary

## `CorrectionBanner`

Correction/retraction and revision navigation.

- Category: `status`
- Surfaces: public, internal
- Variants: correction, retraction, temporary-restriction
- States: active, superseded

### Anatomy

- label
- content
- state
- actions

### Rules

- Cannot be dismissed permanently.

### Accessibility

- announced before main record content

## `CoverageStatement`

Source, period, exclusions and limitations.

- Category: `content`
- Surfaces: public, internal
- Variants: summary, detailed
- States: complete, partial, stale

### Anatomy

- label
- content
- state
- actions

### Rules

- Accompanies entity metrics.

### Accessibility

- plain-language summary

## `DataCollection`

검색·필터·정렬·pagination이 가능한 typed record collection.

- Category: `collection`
- Surfaces: public, internal
- Variants: cards, table, mixed
- States: loading, ready, empty, filtered-empty, partial, stale, invalid-filter, error

### Anatomy

- scope and freshness
- search
- filters
- selected filters
- result count
- records
- pagination
- empty/error

### Rules

- Filter state is URL-serializable.
- No infinite scroll baseline.
- Result count is approximate only when labeled.

### Accessibility

- filter changes announced
- table headers and captions
- pagination labels include destination

## `DataTable`

Sortable, filterable record table.

- Category: `data`
- Surfaces: public, internal
- Variants: comfortable, compact, selectable
- States: loading, empty, partial, error

### Anatomy

- label
- content
- state
- actions

### Rules

- Responsive transformation preserves labels.

### Accessibility

- caption
- sort announcement
- keyboard row actions

## `DecisionReceipt`

Immutable command/submission result.

- Category: `decision`
- Surfaces: internal, response, public
- Variants: publication, response, correction, role
- States: complete, pending-projection, partial-failure

### Anatomy

- label
- content
- state
- actions

### Rules

- Includes ID and absolute time.

### Accessibility

- persistent page, not toast only

## `DecisionReviewPanel`

immutable snapshot을 기준·diff·blocker와 함께 독립 검토한다.

- Category: `decision`
- Surfaces: internal
- Variants: review, publication, correction, rule-activation
- States: ready, blocked, stale, reauth-required, submitting, receipt, conflict

### Anatomy

- snapshot identity/hash
- author and reviewer independence
- criteria
- claim/evidence diff
- blockers
- reason
- decision
- reauth
- receipt

### Rules

- Stale snapshot cannot be approved.
- Reviewer cannot approve own work where separation is required.
- Reason is mandatory.

### Accessibility

- criteria grouped semantically
- decision buttons describe consequence
- receipt announced

## `DistributionChart`

Target relative to cohort distribution.

- Category: `data`
- Surfaces: public, internal
- Variants: dotplot, boxplot, histogram
- States: complete, small-sample, extreme-outlier

### Anatomy

- label
- content
- state
- actions

### Rules

- Tooltip is not sole information source.

### Accessibility

- text summary and equivalent table

## `EmptyState`

Explain true zero, filtered zero, coverage gap or permission state.

- Category: `feedback`
- Surfaces: public, internal, response
- Variants: true-empty, filtered, coverage, permission
- States: default

### Anatomy

- label
- content
- state
- actions

### Rules

- Never collapse unknown into zero.

### Accessibility

- heading and actionable next step

## `EnvironmentBanner`

Staging/demo/security context.

- Category: `status`
- Surfaces: internal, response
- Variants: development, staging, synthetic
- States: persistent

### Anatomy

- label
- content
- state
- actions

### Rules

- Synthetic data environment must never resemble production.

### Accessibility

- text, not color alone

## `ErrorSummary`

Form-wide error list linked to fields.

- Category: `form`
- Surfaces: public, internal, response
- Variants: validation, server
- States: visible

### Anatomy

- label
- content
- state
- actions

### Rules

- Matches inline error text.

### Accessibility

- focus on submit error
- links to fields

## `EvidenceCitation`

Stable evidence reference opening context.

- Category: `evidence`
- Surfaces: public, internal
- Variants: inline, footnote
- States: available, restricted, source-lost

### Anatomy

- label
- content
- state
- actions

### Rules

- Citation ID remains stable per publication revision.

### Accessibility

- button or link semantics
- focus return

## `EvidenceDrawer`

Source, locator, hash and related claim context.

- Category: `evidence`
- Surfaces: public, internal
- Variants: side-panel, full-screen-sheet
- States: loading, available, restricted, error

### Anatomy

- label
- content
- state
- actions

### Rules

- Does not expose internal notes on public surface.

### Accessibility

- dialog/region semantics
- focus trap only when modal
- close and return focus

## `EvidenceLedger`

claim에서 원본까지 provenance와 restriction을 추적한다.

- Category: `evidence`
- Surfaces: public, internal
- Variants: public, internal, review
- States: available, restricted, source-lost, verification-pending, redacted, error

### Anatomy

- evidence index
- citation
- source metadata
- locator
- hash
- provenance
- verification
- redaction
- related claims

### Rules

- Public view never exposes internal notes.
- Provenance gap is explicit.
- Hash and locator are copyable.

### Accessibility

- stable citation labels
- drawer returns focus
- restricted reason is textual

## `FieldError`

Specific correction guidance.

- Category: `form`
- Surfaces: public, internal, response
- Variants: inline
- States: invalid

### Anatomy

- label
- content
- state
- actions

### Rules

- Preserve input.

### Accessibility

- describedby association

## `FileUploadQueue`

Upload, progress, scan, metadata and removal.

- Category: `form`
- Surfaces: response, public, internal
- Variants: response, evidence
- States: queued, uploading, scan-pending, clean, rejected, error

### Anatomy

- label
- content
- state
- actions

### Rules

- No submit before required scans complete.

### Accessibility

- file input alternative
- per-file status announced

## `FilterBar`

Search filters with URL/share state where applicable.

- Category: `search`
- Surfaces: public, internal
- Variants: inline, sidebar, compact-sheet
- States: default, applied, invalid

### Anatomy

- label
- content
- state
- actions

### Rules

- Unknown public filters produce validation feedback.

### Accessibility

- labels
- selected chips removable
- result update announced

## `FreshnessNotice`

Source/data age and affected scope.

- Category: `status`
- Surfaces: public, internal
- Variants: inline, banner, card
- States: fresh, partial-stale, stale, incident

### Anatomy

- label
- content
- state
- actions

### Rules

- Appears adjacent to affected data.

### Accessibility

- timestamp and impact in text

## `GateChecklist`

Publication/review/activation readiness.

- Category: `decision`
- Surfaces: internal
- Variants: publication, rule, source
- States: complete, blocking, not-applicable, stale

### Anatomy

- label
- content
- state
- actions

### Rules

- Server recalculates on command.

### Accessibility

- status text per item

## `GuidedFormSection`

한 논리적 질문 단위의 안전한 입력과 검토를 제공한다.

- Category: `form`
- Surfaces: public, response, internal
- Variants: response, correction, contact, configuration
- States: draft, saving, saved, validation-error, server-error, offline, session-expiring

### Anatomy

- step title
- purpose/privacy note
- fields
- inline errors
- help
- save state
- navigation

### Rules

- Save and submit are distinct.
- No destructive navigation without draft warning.
- Sensitive text is never sent to analytics.

### Accessibility

- error summary
- field errors linked
- inputs retained after failure
- progress communicated

## `IdentityBlock`

Official identity and change/ambiguity.

- Category: `content`
- Surfaces: public, internal
- Variants: agency, supplier, contract, source
- States: verified, ambiguous, merged, split

### Anatomy

- label
- content
- state
- actions

### Rules

- Shared attribute is not legal relationship.

### Accessibility

- name and qualifiers

## `KnownUnknownResponse`

Top-level known facts, critical unknowns and party response.

- Category: `evidence`
- Surfaces: public, internal
- Variants: three-column, stacked
- States: complete, no-response, partial

### Anatomy

- label
- content
- state
- actions

### Rules

- Mobile order is Known, Unknown, Response.

### Accessibility

- ordered headings and list semantics

## `LongFormArticle`

Versioned policy and methodology content.

- Category: `content`
- Surfaces: public
- Variants: policy, methodology
- States: current, superseded

### Anatomy

- label
- content
- state
- actions

### Rules

- Effective date and change history.

### Accessibility

- TOC, heading hierarchy, 72ch

## `MetricWithContext`

Value with unit, cohort, denominator, timeframe and caveat.

- Category: `data`
- Surfaces: public, internal
- Variants: single, comparison, trend
- States: normal, unknown, stale

### Anatomy

- label
- content
- state
- actions

### Rules

- No standalone price-multiple hero.

### Accessibility

- full text equivalent

## `NotificationBanner`

Important non-field status and incident.

- Category: `feedback`
- Surfaces: public, internal, response
- Variants: info, success, warning, critical
- States: persistent, dismissible

### Anatomy

- label
- content
- state
- actions

### Rules

- Critical records are not dismissible without persistent trace.

### Accessibility

- role chosen by urgency

## `OperationsStatusPanel`

incident·health·SLO·telemetry gap과 bounded action을 표시한다.

- Category: `operations`
- Surfaces: internal, public
- Variants: public-status, internal-incident, service-health
- States: healthy, degraded, incident, telemetry-gap, recovering

### Anatomy

- overall state
- affected scope
- started/updated time
- metrics
- affected objects
- safe actions
- runbook
- history

### Rules

- Telemetry absence is not healthy.
- Credentials and payloads are redacted.
- Emergency actions require reason and reauth.

### Accessibility

- status text and icon
- metrics have textual summary
- actions state exact scope

## `PageHeader`

Title, status, metadata and primary action.

- Category: `layout`
- Surfaces: public, internal, response
- Variants: public-record, workspace, form, policy
- States: default, corrected, blocked

### Anatomy

- label
- content
- state
- actions

### Rules

- Public record puts state before sensational metric.

### Accessibility

- single h1
- actions labelled

## `Pagination`

Cursor/page navigation.

- Category: `navigation`
- Surfaces: public, internal
- Variants: cursor, numbered
- States: first, middle, last

### Anatomy

- label
- content
- state
- actions

### Rules

- Infinite scroll is not baseline.

### Accessibility

- nav label
- current page
- focus result heading after navigation

## `PrimaryNavigation`

Global task navigation.

- Category: `navigation`
- Surfaces: public, internal
- Variants: horizontal, sidebar, compact-dialog
- States: default, current, collapsed

### Anatomy

- label
- content
- state
- actions

### Rules

- Visibility is not authorization.

### Accessibility

- current page uses aria-current
- keyboard order follows visual order

## `ProvenanceTrail`

Raw to normalized to rule to publication chain.

- Category: `evidence`
- Surfaces: public, internal
- Variants: linear, detailed
- States: complete, gap, restricted

### Anatomy

- label
- content
- state
- actions

### Rules

- Gap is explicit, never silently bridged.

### Accessibility

- ordered list alternative

## `ReasonDialog`

High-impact action target, impact, reason and reauth.

- Category: `decision`
- Surfaces: internal
- Variants: publish, retract, kill-switch, role
- States: ready, blocked, reauth-required

### Anatomy

- label
- content
- state
- actions

### Rules

- Generic yes/no confirmation forbidden.

### Accessibility

- dialog title names action and object

## `ReauthPrompt`

Step-up before high-impact command.

- Category: `security`
- Surfaces: internal
- Variants: webauthn, mfa
- States: required, verifying, failed, complete

### Anatomy

- label
- content
- state
- actions

### Rules

- No app-native password collection.

### Accessibility

- preserves context and draft

## `ResponsePanel`

Party response, submitted date, consent and verification.

- Category: `evidence`
- Surfaces: public, internal
- Variants: public-excerpt, internal-intake
- States: not-requested, requested, no-response, submitted, verified

### Anatomy

- label
- content
- state
- actions

### Rules

- No response is never admission.

### Accessibility

- speaker and date explicit

## `RevisionAndCorrectionPanel`

revision·정정·철회·temporary restriction을 연결한다.

- Category: `publication`
- Surfaces: public, internal
- Variants: revision-list, correction, retraction, restriction
- States: current, superseded, corrected, retracted, restricted

### Anatomy

- current revision
- status banner
- reason
- affected claims
- diff
- previous/next links
- effective time
- decision receipt

### Rules

- Past revision is immutable.
- Correction cannot be permanently dismissed.
- Retraction keeps a visible tombstone.

### Accessibility

- banner precedes content
- diff readable without color
- revision links describe state

## `RevisionTimeline`

Publication and correction history.

- Category: `history`
- Surfaces: public, internal
- Variants: public, audit-linked
- States: single, multiple, retracted

### Anatomy

- label
- content
- state
- actions

### Rules

- Historical revisions remain reachable.

### Accessibility

- ordered list
- absolute timestamps

## `SaveStatus`

Unsaved/saving/saved/conflict state.

- Category: `feedback`
- Surfaces: internal, response
- Variants: autosave, manual
- States: unsaved, saving, saved, failed, conflict

### Anatomy

- label
- content
- state
- actions

### Rules

- Never claim saved without server acknowledgement.

### Accessibility

- polite live region

## `SearchResultCard`

Typed result with match reason and state.

- Category: `search`
- Surfaces: public, internal
- Variants: case, contract, agency, supplier, internal
- States: normal, stale, corrected

### Anatomy

- label
- content
- state
- actions

### Rules

- Never leak private hit context.

### Accessibility

- heading and descriptive link

## `SensitiveDataNotice`

Privacy, legal or access classification.

- Category: `security`
- Surfaces: internal, response
- Variants: privacy, confidential, restricted
- States: active

### Anatomy

- label
- content
- state
- actions

### Rules

- Does not rely on icon.

### Accessibility

- text and action

## `SignalTriagePanel`

signal의 규칙·data quality·비교 가능성·중복을 검토하고 triage한다.

- Category: `investigation`
- Surfaces: internal
- Variants: price, concentration, split-contract, generic
- States: new, assigned, needs-data, dismissed, linked, conflict

### Anatomy

- signal identity
- rule explanation
- target
- data quality
- comparison
- duplicates
- blockers
- assignment
- decision reason

### Rules

- Signal score is not corruption probability.
- Data blockers precede triage action.
- Dismissal remains auditable.

### Accessibility

- decision options grouped
- rule calculation has text equivalent
- reason errors summarized

## `StatusAndRevisionHeader`

객체 상태·revision·freshness·identity를 최상단에 고정한다.

- Category: `header`
- Surfaces: public, internal
- Variants: public-case, entity, workspace, decision
- States: current, corrected, retracted, blocked, stale

### Anatomy

- status badge
- revision/version
- published/updated time
- title
- summary
- freshness
- primary action

### Rules

- Status precedes metrics.
- Correction/retraction banner precedes title.
- No sensational metric in title.

### Accessibility

- single h1
- timestamps have machine-readable datetime
- status not color-only

## `StatusBadge`

Textual state with semantic styling.

- Category: `status`
- Surfaces: public, internal, response
- Variants: full, compact
- States: neutral, info, warning, success, critical

### Anatomy

- label
- content
- state
- actions

### Rules

- Public and internal state vocabulary are separate.

### Accessibility

- text and icon, never color only

## `StepIndicator`

Multi-step progress.

- Category: `form`
- Surfaces: response, public
- Variants: linear, compact
- States: not-started, current, complete, error

### Anatomy

- label
- content
- state
- actions

### Rules

- Does not imply submission before final step.

### Accessibility

- current step programmatically marked

## `StructuredContentSection`

정해진 제목·설명·body·actions를 일관된 section hierarchy로 표시한다.

- Category: `layout`
- Surfaces: public, internal, response
- Variants: default, subtle, bordered, dense
- States: ready, loading, empty, partial, error

### Anatomy

- heading
- description
- body
- supporting metadata
- actions

### Rules

- Do not turn every section into a card.
- Empty state explains scope.
- Spacing follows token scale.

### Accessibility

- heading level passed by page
- region label when needed
- actions follow body

## `TaskCard`

Role-aware required task.

- Category: `workflow`
- Surfaces: internal
- Variants: due, blocked, incident
- States: open, blocked, complete, overdue

### Anatomy

- label
- content
- state
- actions

### Rules

- Derived from source state, not separate truth.

### Accessibility

- action describes object

## `ToastRegion`

Transient low-risk feedback.

- Category: `feedback`
- Surfaces: public, internal, response
- Variants: success, info, error
- States: visible

### Anatomy

- label
- content
- state
- actions

### Rules

- Never sole receipt for high-impact action.

### Accessibility

- polite/assertive appropriately

## `UnifiedSearch`

기관·업체·계약·사건을 typed result로 검색한다.

- Category: `search`
- Surfaces: public, internal
- Variants: home, header, full-search, internal
- States: idle, typing, loading, results, empty, error

### Anatomy

- label
- query input
- scope selector
- submit
- suggestions
- recent/empty/error
- privacy note

### Rules

- Suggestions never imply accusation.
- Query is not logged when it may contain sensitive personal data.
- Keyboard and form submit both work.

### Accessibility

- combobox semantics
- active descendant
- escape closes
- submit always available


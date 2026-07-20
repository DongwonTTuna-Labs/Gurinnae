# Business-model review R5 (authority-only)

**Verdict: `LGTM_NO_BLOCKING`**

This review uses only the extracted authority tree at
`authority-v13/` (the supplied v13.0.0 ZIP) and the user-requested business
model dimensions. The working-tree `specs/database/addendum/**` files are not
used as authority.

## Current findings

1. **Resolved.**
   Authority screen `authority-v13/specs/ui/screens/PUB-023.md` requires the
   anonymous funding page to answer who provides money, whether money can
   influence investigations, and how operating costs are spent; its sections
   are principles, income, expenses, donors, conflicts and reports. The current
   endpoint now uses `funding_content()` (`services/public-api/src/service/mod.rs:85`,
   implemented in `services/public-api/src/service/public_funding.rs:1-24`):
   it gives substantive independence/threshold policy text, dynamic `asOf`,
   source links and explicit UNKNOWN for unsigned disclosure values. The
   public-api crate tests cover the response helper and the nested-private
   shape rejection.

2. **Stage 2/3 monetization is a roadmap, not a current blocker.**
   The authority business model defines public-benefit pilot, membership/data
   products (paid quota, bulk export, webhooks, snapshots, SLA, newsroom
   workspace) and institutional audit SaaS, while keeping public facts free
   (`authority-v13/docs/02-governance-and-revenue.md:28-55,61-97`); these are
   future stages. The current product is treated as the Stage 1 public-benefit pilot;
   its implemented activation is the verified update subscription
   (`apps/public-web/src/routes/subscribe/screen.ts:1-86`;
   `services/submission-api/src/service/subscription.rs:9-234`). Do not claim
   paid revenue readiness until a later authority revision explicitly moves
   the product to Stage 2/3.

3. **Resolved with fail-closed disclosure semantics.**
   Authority requires quarterly disclosure of donor/customer concentration,
   source purpose, government/party/procurement relationships, conflicts and
   policy-violation requests, with 15%/25% oversight thresholds and a 5%
   related-party review trigger (`authority-v13/docs/02-governance-and-revenue.md:120-136`).
   `funding_content()` exposes the threshold policy and fail-closed UNKNOWN,
   while `listTransparencyReports` remains a public summary projection
   (`services/public-api/src/service/public_tail.rs:1-40`). The scalar privacy
   helper and its regression tests are adjacent at
   (`services/public-api/src/service/public_tail.rs:42-80`). The reader now
   permits only the five disclosure keys and bounded numeric/boolean scalar
   values; text, nested objects and arrays are rejected and covered by unit
   tests, so donor contacts, internal notes and private conflict details cannot
   be stringified into the anonymous response. The Stage 1 fixture intentionally contains only
   `publishedCases` and `corrections`
   (`db/test-fixtures/public-projection-seed.sql:102-103`), which renders as
   UNKNOWN rather than fabricated revenue.

4. **Resolved as an explicit implementation delta, not authority.**
   The current design/provenance record marks the 0025–0030 commercial and
   journey addenda as owner additive migrations and `NON_AUTHORITY_PROPOSAL`
   where they have no mapping to the supplied ZIP. They must remain clearly
   separated from authority claims and must never turn a proposal into an LGTM
   row; this review no longer treats their existence alone as a business
   blocker.

## Verification

- `cargo check -p gurine-public-api` PASS.
- `cargo test -p gurine-public-api` PASS (4 tests, including public report
  scalar privacy/allowlist cases).
- `docs/DESIGN.md` and the design-freeze provenance record classify unmapped
  addenda as `NON_AUTHORITY_PROPOSAL`; they are not used as authority claims.

### Evidence digests (current working tree)

The implementation references above are pinned to the following SHA-256
digests so a later review can detect stale line references or source drift:

```text
services/public-api/src/service/public_funding.rs
903790acfd592d5eb31a8a97152f4ce852240bcb6e1f816847bcba2fa9b495c4
services/public-api/src/service/public_tail.rs
3ef26323d7d798387b56fce482542011e23c563003d46a0026f46a1bfb7dfde7
services/public-api/src/service/mod.rs
dd11bc25e95f88fea688058f7a61ce4a28749bbc459af8bf6684095b13bce0ef
db/migrations/0030_v13_submission_session_hardening.sql
5b267bfd9bcbca32b445b38194bc53007c19a53e3bde3d510f5634f40c97b4bd
```

## Non-blocking follow-up

- Keep the Stage 1 pilot boundary explicit; defer paid quota/export/SLA/
  workspace billing until an authority revision authorizes Stage 2/3.
- Add independent oversight/board gates, related-party recusal and public
  disclosure evidence before accepting any real funding revision.

Stage 2/3 paid quota, export, SLA, workspace and audit-SaaS flows remain a
roadmap item under `authority-v13/docs/02-governance-and-revenue.md`; they must
not be advertised as current Stage 1 revenue readiness without a new authority
revision.

## R5 revalidation (2026-07-19)

The current working tree preserves the authority screen contracts after the
journey/UI closure changes: `PUB-023` keeps the `DecisionReviewPanel` conflict
section and `PUB-029` keeps the `AgentSuggestionPanel` verification section.
Current evidence digests are:

```text
apps/public-web/src/routes/about/funding/screen.ts
4e9fedff0f2f2e55979045a0aeace1846fa30cb2ac6e0e4c5ce0b96bf2e2bf50
apps/public-web/src/routes/subscribe/screen.ts
ee4602534e6beaadc391f0716571b6b3f705bcc45c574339cbb4c99f711bc6f8
services/submission-api/src/service/subscription.rs
8e60c56b207d6d753e1fc41afefef0b635b7d244028cef8ebae4f9fd317b4531
```

`cargo test -p gurine-public-api` passed (4/4). No implementation change
introduces payment, advertising, pay-to-remove, or customer-priority inputs;
therefore the authority-only verdict remains `LGTM_NO_BLOCKING`.

## R6 fresh review (2026-07-19)

The latest source/evidence was re-read after the operations-screen closure. The
authority `OPS-004` contract is again the six-section cost/budget screen
(`envelope`, `spend`, `forecast`, `limits`, `alerts`, `changes`); the
non-authority `BusinessHealth` section was removed from its screen registry.
Commercial addendum projection code remains non-authority and is not surfaced as
a Stage 1 public or paid-readiness claim. The current SSR trace records the
budget projection as `BLOCKED` with an error summary, which is the required
fail-closed cost-control state rather than fabricated spend or revenue.

Fresh checks:

```text
cargo test -p gurine-public-api                         PASS (4/4)
bun run --filter '@gurine/public-web' check             PASS
bun run --filter '@gurine/ui' check                    PASS
```

Current screen/source digests:

```text
apps/review-console/src/routes/internal/operations/budgets/screen.ts
db56eba5d37e3ce65cba9e54f18cd500e89223a1151eeb6072bb36b9857e846b
apps/public-web/src/routes/about/funding/screen.ts
4e9fedff0f2f2e55979045a0aeace1846fa30cb2ac6e0e4c5ce0b96bf2e2bf50
apps/public-web/src/routes/subscribe/screen.ts
ee4602534e6beaadc391f0716571b6b3f705bcc45c574339cbb4c99f711bc6f8
services/submission-api/src/service/subscription.rs
8e60c56b207d6d753e1fc41afefef0b635b7d244028cef8ebae4f9fd317b4531
```

No business-model blocker was found. Verdict remains `LGTM_NO_BLOCKING`.

## R7 fresh review supersession (2026-07-19)

`R6` is superseded by this finding. The latest runtime evidence shows a
business-value delivery blocker on the authority funding surface:

- `services/public-api/src/service/public_funding.rs` returns the typed
  authority `FundingContentResponse` with the disclosure content under
  `data.sections`.
- `packages/ui/src/generated-screen-projections.ts` binds PUB-023 fields to
  `getFundingContent` paths `$.principles`, `$.income`, `$.expenses`,
  `$.donors`, `$.conflicts`, and `$.reports`, none of which exist in that
  response envelope.
- `implementation-evidence/runtime-traces/pub-023.json` therefore records
  every PUB-023 section as `projectionState: EMPTY` despite HTTP 200 SSR.

This violates the authority PUB-023 purpose (immediate funding, independence,
cost, donor-threshold and report answers) and the business value proposition:
the anonymous trust/disclosure page currently renders no disclosure content.
The fix must be a closed, screen-owned `Pub023ScreenVmV1` mapper at the
server/browser projection boundary (including `data.sections` and the
transparency-report projection), followed by regenerated bindings and a fresh
SSR trace showing the sections `READY` or truthful per-section `UNKNOWN` with
the actual content present. Do not flatten arbitrary top-level fields into the
OpenAPI response; the authority response schema must remain unchanged.

**Fresh verdict: `CHANGES_REQUIRED` (exact blocker: PUB-023 typed projection
path/envelope mismatch).**

## R8 fresh re-review (2026-07-19)

R7 is superseded. The closed PUB-023 projection mapper is now present and the
mock read route supplies a schema-valid nested `FundingContentResponse` plus the
transparency-report response. A fresh SSR trace at
`implementation-evidence/runtime-traces/pub-023.json` (17:59:05Z) records all
six authority sections as `READY`, HTTP 200, one heading, and no error summary.
The projection unit test covers nested `data.sections` and passes.

Fresh checks:

```text
bash scripts/test-public-flow.sh                         PASS (41 operations)
cargo test -p gurine-public-api                           PASS (4/4)
bun run --filter '@gurine/ui' test                      PASS (35/35)
bun run --filter '@gurine/public-web' check              PASS
bun run --filter '@gurine/ui' check                      PASS
PUB-023 runtime trace (Playwright, fresh build)          PASS (1/1; all READY)
```

The authority-only business boundary remains intact: public facts/evidence and
basic subscription are free; Stage 2/3 quota/export/SLA/workspace/audit-SaaS
remain roadmap-only; no payment, advertising, pay-to-remove, or customer/funder
priority input reaches editorial detection or publication. OPS-004 is the
authority six-section cost/budget surface and reports BLOCKED with an error
summary when its evidence is unavailable, never fabricated revenue or spend.

Current evidence digests:

```text
packages/ui/src/screen-projection-specialized.ts
146e40dc26bfb33da333f4e96f612a7e27acd3da4a615d7cee6b0de02c3b35dd
packages/ui/src/screen-projection.test.ts
bd87a9ffaf12cfa44860b7d31b46424a2dd5601fd3d153c78a0af957000761ac
tests/e2e/support/mock-api-reads.ts
42a8402a99d77439326cef78631d077f4a9e7f3a7e6cbdabf39f7f4c90be474a
implementation-evidence/runtime-traces/pub-023.json
5ed2a3103567e055f8f1f2dccb6d5723de6ff751089f86a58c995f4f22b7b9ff
```

**Fresh verdict: `LGTM_NO_BLOCKING`.**

## R9 fresh re-review (2026-07-19)

This re-review covers the latest source tree after the `0030` submission-
session migration was extended with the COMMUNICATION_V1 owner routines and
after `MANIFEST.md`/`MANIFEST.sha256` were regenerated.  The new routines add
durable claim/lease/attempt, provider response/callback/poll observation,
suppression/opt-out fences, and receipt/outbox chaining.  They do not introduce
payment, advertising, pay-to-remove, funder-priority, or personal-data
monetisation inputs into the Stage 1 product boundary.  Communication consent,
approval, and cost controls remain operational safeguards; Stage 2/3 paid
quota/export/SLA/workspace/audit-SaaS remain roadmap-only.

The authority commercial surfaces remain unchanged:

- `PUB-023` funding disclosure remains the anonymous, evidence-first trust
  surface (fresh trace has all six sections `READY`).
- `PUB-029` remains the verified-update subscription path; no paywall or
  editorial-priority coupling was added.
- `OPS-004` remains a cost/budget authority read and the current runtime trace
  fails closed as `BLOCKED` with an error summary when evidence is unavailable;
  it does not fabricate revenue, spend, or margin.

Current evidence digests:

```text
db/migrations/0030_v13_submission_session_hardening.sql
6cd8c0365bc0424db24cce2e1d264cc92fb717f86ccc2d40e9d893ce601fff01
MANIFEST.md
61b087f0df818db89f37e931572ad41ceacd467e46107bcd3eb3809a5bb1317f
MANIFEST.sha256
b7268aa224f2e33edb1b8c3dd588d0557bcf72fe533df3d60a2c447170d53507
apps/public-web/src/routes/about/funding/screen.ts
4e9fedff0f2f2e55979045a0aeace1846fa30cb2ac6e0e4c5ce0b96bf2e2bf50
apps/public-web/src/routes/subscribe/screen.ts
ee4602534e6beaadc391f0716571b6b3f705bcc45c574339cbb4c99f711bc6f8
services/submission-api/src/service/subscription.rs
8e60c56b207d6d753e1fc41afefef0b635b7d244028cef8ebae4f9fd317b4531
apps/review-console/src/routes/internal/operations/budgets/screen.ts
db56eba5d37e3ce65cba9e54f18cd500e89223a1151eeb6072bb36b9857e846b
services/control-api/src/service/query_business.rs
6689277c533daace13fe25617762ecaafcc623dd065216af4c53f05182787735
services/egress-gateway/src/communication_adapter.rs
2acd79fec74d09aafb92b71f3defa33b204ec0723fe7d3abfdedbd465f9ea0276
services/notification-worker/src/notification_typed_delivery_body.rs
894d88cf01bbeb2155931d961ddb9b41b31a2e4372667634e76bb22317ccd044
services/notification-worker/src/notification_typed_observation_body.rs
6217f1e469cdac48b872ff4a06470ed7e1bcff9f2cb6f1ee5c41c263a877e3bd
implementation-evidence/runtime-traces/pub-023.json
5ed2a3103567e055f8f1f2dccb6d5723de6ff751089f86a58c995f4f22b7b9ff
implementation-evidence/runtime-traces/ops-004.json
5759dd106807c38708f45e8c82cf4be4a5da53e2efa996f565379b8b02229fc2
```

The OpenAPI source still contains a historical `getBudgetOverview` response
reference to `BusinessHealthResponse` while the current screen registry and
owner query declare `BudgetOverviewResponse`.  This is a generator/contract
parity follow-up for the PdM/QA gate, not a change to ICP, pricing, revenue,
acquisition, activation, retention, or risk economics; the business-model
verdict below is therefore limited to the commercial boundary.

**Fresh verdict: `LGTM_NO_BLOCKING` (business-model scope).**  Global release
remains blocked by the independent AI-runtime/PdM findings until those gates
also reach LGTM.

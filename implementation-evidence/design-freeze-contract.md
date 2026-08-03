# Design bundle and release freeze contract

Status: `FINAL`

This contract prevents a declaration, copied count, partial review, or test runner
that executed nothing from turning the Gurinnae design/release gate green. It is
mechanical policy for the sole v13 authority identified by SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`.
It does not make an incomplete design authoritative and does not replace
`AGENTS.md`, `FINAL_BUILD_CONTRACT.md`, or a PostgreSQL/runtime hard gate.

## Two results, never one ambiguous PASS

`STRUCTURE_LINT` validates enumerated registries, references, source-derived
counts, and exact set witnesses. `RELEASE_FREEZE` additionally validates FINAL
status, closed current-truth blockers/conflicts, the pinned authority archive and
migration bases, same-digest independent reviews, and executable non-skipped
tests. A lint pass is not a release pass. `RELEASE_FREEZE` cannot pass when
`STRUCTURE_LINT` fails.

Commands:

```bash
PYTHONDONTWRITEBYTECODE=1 python -B scripts/generate_effective_registry.py
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validation/design_freeze.py --mode lint
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validation/design_freeze.py --self-test
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validation/design_freeze.py --mode freeze
```

The first two commands may fail during design work and the final command must
fail until every release condition exists. No caller may translate failure into
a warning, skip it, or reuse a prior JSON result after any included byte changes.

## Canonical digest membership

`scripts/design_bundle_digest.py` first verifies the exact authority archive. It
then discovers, glob-sorts, and hashes each canonical member using a domain tag
and repeated length-delimited `relative path UTF-8 + exact file bytes`. It does
not hash a manually maintained list of content hashes.

Membership includes:

- the product constitution, conflict registry, domain/screen closure, common
  expert prompt, this freeze contract, base acceptance lock, authority-lock
  verifier, and hash-pinned authority evidence;
- every file absent from the v13 manifest under the normative database, product,
  UI, agent, parser, submission, and business specification domains, regardless
  of whether its filename says addendum, contract, schema, fixture, or generator;
- every supplemental acceptance feature, mapping, fixture, schema, or runner
  absent from the v13 acceptance tree;
- every current design generator and Python validator selected by the canonical
  generator/validator globs.

Review records are not digest members because a record cannot be part of the
digest it attests. Application source and implementation tests are also not
design members; their later creation does not invalidate a correct design review,
but the release freeze independently requires the mapped tests to exist.

The manifest exposes `bundle_sha256`, `member_manifest_sha256`, member count,
category counts, and every member path, byte size, and SHA-256. Any member path or
byte change creates a new bundle digest and makes prior records inapplicable.

## Source-derived effective registry

The generator enumerates IDs and calculates counts. A count is only a checked
projection of a set and is never a target to preserve. In particular, table,
migration, state-machine, lifecycle, occurrence, and action totals may change
when an explicit required object is added; validators must update consumers from
the enumerated set rather than hiding the object to retain an old number.

The following witnesses are exact unless a higher authority explicitly defines a
different base subset, in which case that subset remains separately named:

- base operations equal base persistence and base traceability; additive owner
  operations equal operation contracts, screen bindings, transaction mappings,
  exact persistence, and resource/error bindings;
- operation-kind commands equal command semantics, exact command persistence,
  and state-machine operation dispositions; callback IDs equal callback
  semantics, persistence, and resource bindings;
- additive event IDs equal the owner event delta, have no base collision, and all
  command, machine, and domain references resolve in the effective event set;
- additive table IDs equal the owner table list, migration ownership flattening,
  and physical table contracts; final physical tables derive from base tables,
  explicit renames, and additions;
- additive migration names equal owner, persistence, and global plans, and every
  planned ordinal has physical fragments; runtime migration completeness is
  delegated to and then fail-closed against the authority-lock verifier;
- derived sessions equal cookie/session profiles, their allowed operations equal
  the authorization overlay, and every reference resolves to an operation;
- screen IDs are equal across catalog, trace, design closure, effective screens,
  and accessibility contracts; catalog actions equal closure actions;
  navigation actions equal navigation focus contracts; every additive command
  has at least one typed screen placement;
- profile and special-state occurrence IDs are regenerated per screen and are
  exact with the executable occurrence registry; template IDs equal the
  archetype profile/state Cartesian set;
- per-screen operation traces are exact between screen closure and typed
  effective screen contracts; all additive operations are present in the
  additive screen trace;
- base and supplemental feature scenario IDs are exact with their respective
  executable mappings, do not collide, and overlays address existing base IDs.

Duplicate IDs, unknown references, a declared-count mismatch, missing witness,
or a nonregular/symlink member fails structure lint.

## FINAL and current-truth closure

Before release freeze, `DESIGN.md` and every top-level status-bearing normative
YAML member must say exactly `FINAL`. `REVIEW_REQUIRED`, `DESIGN_READY`,
`IMPLEMENTED`, a missing status, or an unrecognized spelling is not equivalent.

Every top-level `blockers`, `known_blockers`, `remaining_blockers`,
`design_blockers`, `release_blockers`, or `open_decisions` value must be empty or
the exact sentinel `CLOSED_CURRENT_TRUTH`; a retained structured history row is
allowed only when its own `status` is exactly `CLOSED_CURRENT_TRUTH`. Every status row in
`implementation-evidence/spec-conflicts.md` must be
`CLOSED_CURRENT_TRUTH`. Historical prose such as “fixed” or “accepted” is not a
machine-readable closure.

## Independent review records

Current records live at `implementation-evidence/reviews/final/*.yaml`. Historical
Markdown reports are provenance and provide prior finding IDs; they never count
as current LGTM. The canonical set and legacy one-to-one aliases are owned by
`implementation-evidence/expert-review-roles.yaml`; the validator reads that
registry rather than a hard-coded role tuple. Exactly one current record is
required for each canonical role:

- `PDM`
- `PRODUCT_DESIGN`
- `ACCESSIBILITY_RESPONSIVE`
- `BUSINESS_MODEL`
- `AI_MULTIMODAL_RESEARCH`
- `DATA_VISUALIZATION`
- `DATABASE`
- `COMMAND_EVENT_LIFECYCLE`
- `HUMAN_APPROVAL`
- `OMNICHANNEL_SESSION`
- `SRE_FINOPS`
- `TRUST_PRIVACY_LEGAL`
- `QA_TRACEABILITY`
- `PROCUREMENT_DOMAIN`

The record schema is:

```yaml
schema_version: 1
review_kind: DESIGN_FREEZE
role: PDM
verdict: LGTM
authority_zip_sha256: 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5
design_bundle_sha256: <exact current bundle_sha256>
member_manifest_sha256: <exact current member_manifest_sha256>
reviewed_member_count: <exact current member_count>
independent: true
reviewer_id: <stable nonempty reviewer identity>
reviewed_at: <ISO-8601 timestamp with timezone>
blocking_findings: []
finding_retests:
  - finding_id: <stable prior finding ID>
    status: CLOSED_CURRENT_TRUTH
    evidence: <exact member, registry, or executable evidence>
```

All roles bind one digest. Every prior Markdown finding heading must have a retest
row. P0/P1 can only be `CLOSED_CURRENT_TRUTH`; P2/P3 may instead be
`ACCEPTED_NON_BLOCKING` with evidence. A duplicate current role, split digest,
non-LGTM verdict, nonempty blocking list, missing evidence, repeated reviewer ID,
or absent role fails. Each required role therefore has a distinct independent
reviewer identity.

## Missing, skipped, focused, and zero-test rejection

Every base and supplemental scenario has one mapping with `skip_policy:
FORBIDDEN`, a nonempty implementation path, and an executing command.
Supplemental feature files with zero `scenario-id` declarations fail. Feature
tags that skip, ignore, disable, focus, or select only a subset fail.

At release freeze, every mapped implementation path must be a present regular
UTF-8 file and contain each mapped scenario ID. `test.skip`, `test.fixme`,
`#[ignore]`, pytest/unittest skip, `@Ignore`, `@Disabled`, `test.only`, and focused
equivalents fail. Commands using list, collect-only, or dry-run modes fail. A
successful process exit without at least one mapped scenario in its source is a
zero-test failure, not evidence.

## Authority and migration proof

Release freeze resolves the pinned `authority-v13-frozen` Git tag through
`scripts/git_authority.py` and reads each base migration from the pinned Git
object. It requires the exact pinned tag commit and tree, byte-exact 24-file
specification and runtime migration bases, and the exact 0025–0030 additive
runtime migration set. `scripts/verify_migrations.py` independently preserves
the 24-base plus 6-additive filename/count assertion in `make verify-specs`.

Ordinary implementation changes are verified by the application hard gates;
they are not compared with the frozen tag as though they were base migrations.
Therefore a moved tag, stale base migration, missing 0025–0030 runtime member,
or copied old proof cannot become green through a design status edit.

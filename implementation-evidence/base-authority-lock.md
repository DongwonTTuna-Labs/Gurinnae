# v13 base authority byte lock and migration isolation

Verified on 2026-07-15 UTC against the sole supplied authority archive:

`/home/dongwonttuna/.codex/attachments/29aa0c62-686a-450b-84aa-944e5cb7d47a/gurine-codex-authority-pack-v13.0.0-20260712.zip`

## Pinned authority

- Archive SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
- Archive `MANIFEST.sha256` SHA-256: `6e693b427c3dc048193d62936b0bd9cc66bb79396605ccaf9f9b9b967c964028`
- Manifest entries verified inside the archive: `1,230/1,230`
- Ordered authority-tree digest: `3136450c3d01f950e123ab52813c3992cd7239f1e691166e6694669cffe13f98`
- Authority spec migrations: `24/24` local files are byte-exact with the archive manifest.

The verifier is `scripts/verify_authority_base_lock.py` (SHA-256
`e3ba8f3a403d776c4de73d95b4c5263c863f52d3591b8c08899e73b28bcdd1de`).
Archive scope returns `RESULT: PASS`. Migration scope is fail-closed and returns
nonzero until the exact six-file 0025–0030 set exists:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_authority_base_lock.py --scope archive
PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_authority_base_lock.py --scope migrations
```

The current strict migration command exits `1` with
`additive_migration_missing` for the five reserved physical migrations. Only a
clearly marked diagnostic command can inspect the partial tree without that
final-completeness error:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B scripts/verify_authority_base_lock.py \
  --scope migrations --allow-pending-additive
```

Negative self-tests also removed 0030 from an isolated copy and introduced a
wrongly named ordinal-0025 file. Both diagnostic-flag runs exited `1` with,
respectively, `hardening_migration` and `additive_migration_set`; the flag does
not permit 0030 loss, wrong filenames, duplicate ordinals, or ordinals above
0030.

The explicit diagnostic `--scope full` remains fail-closed. At this checkpoint it reports
`948/1,230` matching authority paths, `282` byte mismatches, and `0` missing
paths, plus the missing 0025–0029 migration-set error (`283` total problems).
Those 282 pre-existing cross-file drifts are not silently classified as additive
and were not changed by this task. The same run emits a separate additive source
inventory and digest; its count is intentionally not frozen while parallel
owners are still editing and must be regenerated at final freeze.

The default and release scope is `migrations`. It verifies the pinned archive,
the same archive digest before and after verification, all 1,230 Manifest
members, the byte-exact 24-file authority migration base in both the spec and
runtime directories, and the exact 0025–0030 runtime migration set. A
repository-local derivation hash can never replace an authority member digest. It
deliberately does not compare ordinary implementation source files to
their authority-pack bytes: `VERIFY.md` requires the implemented Rust/SvelteKit
source tree to be built and verified separately. `--scope full` is retained only
as a diagnostic inventory of authority-origin worktree drift and is not a
release-success criterion.

## Runtime migration isolation

- The three runtime files that had contained implementation derivations are now
  byte-exact with the sole authority: `0009` `9ee58611761ab5cd78d215860924ad37adbaa97498ae32ef5bb26f69f6aa8bbb`,
  `0013` `358592e165505b3a145ef51bcab5285d3f6ef9ba9991f574f5602c8d80ec83a2`,
  and `0024` `57f9f35217b0e0ad992006dc813b60d3a1223966146a0ff82e6e5e6567603b31`.
- The 53 changed or additive PostgreSQL statements formerly mixed into those
  base files were preserved in original ordinal order in
  `db/migrations/0030_v13_submission_session_hardening.sql`, followed by the
  pending-session access-token hardening. No deployed behavior was discarded.
- Migration 0030 SHA-256:
  `3a8be41a2d558f08b7f88b443f68ab11574505c226d4cc8f38913cbcac874d10`
  (`604` lines, `41,253` bytes).
- Runtime base migration lock: `24/24` PASS; ordered digest
  `45a972681c70e9e8cd20bb5453bbc86e5719e82e6abf8c9462249eeeb7963cce`.
- Current diagnostic additive migration inventory: only 0030 is present; digest
  `d9a0ec6768f4504eea57b9ee3c11b602f6f7fbba2a8b1617c826f10fe9bcfe58`.
- No `0025_v13_submission_session_hardening.sql` remains. Ordinals 0025–0029
  remain reserved for the five physical owner-addendum migrations.

Migration 0030 adds these database-enforced invariants without altering 0024:

- one access token per `exchange_session_id`;
- `(exchange_session_id, response_request_id)` must match the session's
  `(id, scope_id)`;
- an exchanged token must have exchange time and revocation time together;
- OTP attempt accounting resolves the exact token for the pending session;
- the status projection exposes the exact internal session ID required for the
  server-side OTP lookup;
- only `gurine_submission_api`, not PUBLIC/public API, retains function execute
  privilege.

## PostgreSQL 18.4 smoke

Clean runtime application used
`postgres:18.4-bookworm@sha256:d9c83446333daec3f0588cc709adb80c26090b7f9f0f7ec8d43c243385d79818`.
The current tree contains 24 base migrations plus 0030, so `25/25` available
migrations applied in filename order. PostgreSQL reported
`server_version_num=180004`; the six product schemas contained the expected 107
base tables after the relocated delta and hardening committed.

Validated catalog objects:

- `submission_sessions_id_scope_key`: validated unique constraint
- `response_access_exchange_session_key`: validated unique constraint
- `response_access_exchange_session_scope_fk`: validated foreign key
- `response_access_exchange_state_check`: validated check constraint

Runtime canaries passed for two distinct access tokens on the same response
request: status returned the selected pending session ID, a failed proof
incremented only that session's token, duplicate session binding was rejected,
cross-request binding was rejected, partial exchange state was rejected, and
the submission role could call both routines while the public API role could
not.

`bash scripts/test-submission-flow.sh` also passed the existing 34-operation
application integration. That flow applies every available runtime migration,
creates two access tokens for the same response request, verifies the selected
token through the Submission API, and exercises session rotation, encrypted
payloads, object bytes, notification delivery, and ClamAV scanning.

## Required cross-file count closure

Migration 0030 is a sixth additive migration with zero new tables. The final
count is therefore `24 base + 5 physical addenda + 1 hardening = 30`, not 29.
The following non-owned consumers still require an additive-overlay update
before final freeze:

- `specs/product/owner-addendum-2026-07-14.yaml`: additive migrations `5 -> 6`,
  final migrations `29 -> 30`, and include 0030 in the migration set.
- `specs/database/addendum/global.yaml`: range `0025..0029 -> 0025..0030`,
  additive count `5 -> 6`, final count `29 -> 30`, with 0030 owning zero tables.
- `specs/product/addendum-persistence-contracts.yaml`: count `29 -> 30`, rule
  range through 0030, and explicit empty `0030_v13_submission_session_hardening.sql`
  migration ownership so table set-equality remains unchanged.
- `scripts/validation/design.py`: replace the hard-coded final migration oracle
  `29` with the source-derived overlay count `30`; a zero-table migration must
  be valid without weakening the 77/78-table set-equality gate.
- `implementation-evidence/spec-conflicts.md` and
  `implementation-evidence/hash-pinned-authority-baseline.md`: update the final
  additive/final migration prose without changing the immutable 24-migration
  authority baseline.
- Final PostgreSQL evidence, traceability overlay, source manifest, and archive
  evidence must be regenerated after migrations 0025–0029 exist.

The immutable base files that correctly state the v13 authority count as 24
must remain 24; they are not final owner-addendum count targets.

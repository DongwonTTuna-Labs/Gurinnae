# PostgreSQL·SQLx 최종 정책

상태: **FINAL**  
권위: `specs/database/migrations/**`, `schema-catalog.yaml`, `privilege-matrix.yaml`, `runtime-security-tests.yaml`

## 1. 기준

- PostgreSQL 18.4
- SQLx 0.9.0
- API startup migration 금지
- one-shot migrator
- service별 login/privilege role
- `.sqlx/` metadata commit
- production owner/superuser credential 금지

## 2. Schema

```text
raw       원본 fetch/document/parsed record
core      기관·업체·계약·provenance·rule·signal
editorial 조사·근거·claim·소명·review·publication
intake    외부 token-scoped draft/submission
ops       사용자·RBAC·job·event·audit·source·provider·cost
public    승인된 projection
```

정확한 table/function/policy/trigger 목록은 schema catalog를 따른다. 문서상의 예시 목록보다 실제 migration과 catalog가 우선한다.

## 3. 타입

- ID: UUIDv4, API에서는 opaque
- Money/decimal: `numeric`, API에서는 문자열 직렬화
- Currency: ISO 4217 3자
- Timestamp: UTC `timestamptz`
- Date-only source: `date`
- Hash: checked lowercase hex
- Flexible immutable snapshot/source metadata만 JSONB
- Core relationship·권한·상태를 JSONB로 숨기지 않음

Canonical enum은 `specs/domain/state-machines.yaml`과 정확히 일치한다. Persisted 상태는 enum 또는 CHECK로 강제한다.

## 4. SQLx

정적 query는 `query!`/`query_as!`를 우선한다. 동적 query는 allowlisted typed filter/sort와 bound parameter를 사용하는 `QueryBuilder`로 제한한다. SQL 문자열 연결은 금지한다.

```bash
cargo sqlx migrate run --source db/migrations
cargo sqlx prepare --workspace
cargo sqlx prepare --workspace --check
SQLX_OFFLINE=true cargo check --workspace --locked
```

## 5. Transaction

Command transaction:

1. authentication/capability/step-up 확인
2. idempotency request hash 확인
3. aggregate row lock와 expected version 확인
4. domain transition과 invariant 검증
5. exact DB mutation
6. DB-owned audit append
7. 필요한 integration event outbox insert
8. idempotency receipt 저장
9. commit

외부 network/object operation은 transaction 안에서 실행하지 않는다. Durable job과 object digest로 이어간다.

## 6. Lifecycle와 immutability

완전 immutable:

- audit event/checkpoint
- parsed record
- review snapshot/decision
- publication revision

Lifecycle guarded:

- SourceDocument: 허용된 processing transition과 immutable identity/hash
- RuleRun: RUNNING에서 terminal로만 전이, terminal 이후 불변

전면 UPDATE 금지 trigger로 정상 lifecycle을 막지 않는다.

## 7. Audit와 outbox

`ops.append_audit_event`는 DB가 stream head를 잠그고 canonical payload와 이전 hash로 새 hash를 계산한다. Caller가 event hash를 지정하지 못한다. Workflow worker는 외부 secret로 chain head를 서명해 immutable checkpoint를 기록한다.

`ops.enqueue_outbox`는 canonical active event type만 허용한다. State mutation과 outbox insert는 같은 transaction이다.

## 8. Submission 격리

Submission API는 intake table을 직접 write하지 않는다. Fixed-search-path SECURITY DEFINER procedure가 token hash를 검증하고 대상 request/draft를 resolution한다. RLS는 방어층이며 application-procedure boundary를 대체하지 않는다.

- 다른 token/session row 접근 금지
- upload finalize 시 client가 malware scan 결과를 지정하지 못함
- scan 결과는 workflow worker 전용 procedure
- raw token과 plaintext email을 audit/log/event에 기록하지 않음

## 9. Jobs

- `FOR UPDATE SKIP LOCKED`의 짧은 claim transaction
- lease token과 monotonically increasing fencing token
- timeout/cancellation
- bounded retry와 DLQ
- old worker의 completion 거부
- bulk retry는 explicit ID 또는 actor-owned immutable query snapshot
- source retry는 `retry_of_source_run_id`를 보존

## 10. 권한

마지막 privilege closure migration이 이전 broad grant를 모두 reset하고 exact grant를 재적용한다.

- Public API: public SELECT만
- Control API: typed editorial/ops mutation
- Submission API: procedure execution과 idempotency만
- Ingest/Analysis/Projection/Notification/Workflow/Extractor/Scheduler: 별도 role
- Auditor: audit read-only

모든 service login role은 단 하나의 NOLOGIN privilege role만 상속하고 `NOSUPERUSER NOBYPASSRLS`다.

## 11. Runtime security test

정적 SQL 문자열 검색만으로 승인하지 않는다. Ephemeral PostgreSQL 18.4에서 각 role로 실제 SQL을 실행한다.

- cross-schema denial
- cross-token denial
- direct intake mutation denial
- immutable update/delete denial
- invalid lifecycle transition denial
- fixed search_path
- audit checkpoint
- default privilege canary
- no superuser/BYPASSRLS

정확한 case는 `runtime-security-tests.yaml`에 있다.

## 12. Index·성능

현재 query와 acceptance가 요구하는 index만 migration에 둔다. Partition은 volume/retention evidence와 ADR 없이 도입하지 않는다. Critical query는 `EXPLAIN (ANALYZE, BUFFERS)` baseline과 regression test를 가진다.

## 13. Backup·복구

- encrypted PITR
- object versioning
- clean environment restore rehearsal
- audit/hash verification
- public projection rebuild
- deletion/retention 재적용
- RPO/RTO receipt

## 14. 금지

- ORM schema auto-sync
- float money
- unbounded page/query
- application owner role
- migration on API startup
- raw string SQL concatenation
- broad `GRANT ... ALL TABLES`를 final closure 뒤에 추가
- SQLx metadata 누락
- production DB를 test fixture로 사용

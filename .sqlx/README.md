# SQLx offline metadata

Compile-time `sqlx::query!`, `query_as!`, and `query_scalar!` calls are checked
against the migrated PostgreSQL 18.4 schema. Their `query-*.json` metadata is
committed here so database-free builds use the workspace's offline default.

Regenerate metadata after changing a macro query or migration:

```bash
scripts/dev-db.sh up
scripts/dev-db.sh migrate
SQLX_OFFLINE=false DATABASE_URL="$(scripts/dev-db.sh url)" \
  cargo sqlx prepare --workspace -- --all-targets
scripts/dev-db.sh down
```

`make test-sqlx-prepare` creates a clean migrated database and requires an
online `cargo sqlx prepare --workspace --check -- --all-targets` diff check to
pass. `.cargo/config.toml` makes ordinary host Cargo commands offline by default;
an explicit process environment value still overrides it.

## Runtime query inventory

2026-08-03 현재 Rust source에는 runtime query API 호출이 42개 남아 있다.
그중 승인된 예외는 아래 10개뿐이다. 나머지 32개 정적 호출은 아직 예외로
승인되지 않은 `OPEN_QUESTIONS`이며 후속 SQLx 정합 작업 대상이다.

### 승인된 동적 SQL 3개

`services/control-api/src/service/command_support.rs:256,298,312`는 operation
contract가 선택한 relation/column을 `safe_sql_identifier`로 검증하고,
`AssertSqlSafe` 경계에서 bound parameter만 결합하는 동적 concurrency guard다.

### checked macro 구조적 예외 7개

- `services/analysis-worker/src/analysis_provider_lineage.rs:235`: `$3`가
  polymorphic `jsonb_build_object`에서 먼저 사용되어 PostgreSQL describe가
  타입을 결정하지 못한다. SQL에 exact cast를 추가하는 별도 승인 변경 또는
  SQLx/PostgreSQL inference 개선 시 해제한다.
- `services/analysis-worker/src/analysis_runtime_bridge.rs:293`: 같은 이유로
  `$2` 타입을 결정하지 못한다. 해제 조건은 위와 같다.
- `services/analysis-worker/src/analysis_source_use_roots.rs:15`: 같은 이유로
  `$1` 타입을 결정하지 못한다. 해제 조건은 위와 같다.
- `services/ingest-worker/src/ingest_jobs.rs:531`: 같은 이유로
  `jsonb_build_object` 안의 `$2` 타입을 결정하지 못한다. 해제 조건은 위와 같다.
- `services/workflow-worker/src/workflow_action_execution.rs:164,211,343`:
  각각 호출하는 `ops.load_action_execution_v1`,
  `ops.load_action_communication_endpoint_v1`,
  `ops.dispatch_approved_communication_intent_v1`가 migration 0030을 포함한
  현재 migration tree에 존재하지 않아 describe할 수 없다. 권위 migration이
  함수를 materialize하고 offline metadata를 재생성할 때 해제한다.

### OPEN_QUESTIONS 32개

다음 호출은 정적 SQL이거나 정적 SQL 상수를 사용하지만 이 inventory에서
구조적 보류 근거가 확인되지 않았다. 이들은 승인된 예외가 아니다.

- `services/workflow-worker/src/workflow_retention_job.rs:183`
- `services/workflow-worker/src/workflow_response_party_name_correction_job.rs:69,84`
- `services/workflow-worker/src/workflow_response_party_name_correction_delegation.rs:39`
- `services/workflow-worker/src/workflow_entity_retention_job.rs:118`
- `services/scheduler/src/person_retention_scheduler.rs:26`
- `services/scheduler/src/entity_retention_scheduler.rs:26`
- `services/public-api/src/service/legal_content.rs:106`
- `services/projection-worker/src/runner/response_submission_audit.rs:82,96`
- `services/migrator/src/main.rs:51,62`
- `services/projection-worker/src/runner/response_materialized_projection.rs:189,214`
- `services/projection-worker/src/runner/entity_retention_anonymization.rs:169,183,194,243,269,293`
- `services/notification-worker/src/response_submission_notification.rs:46`
- `services/notification-worker/src/privacy_notification_jobs.rs:67,130,155,170`
- `services/control-api/src/service/domains/editorial/official_channel.rs:36,61`
- `services/control-api/src/service/domains/editorial/entity_authority.rs:42,67`
- `services/control-api/src/service/domains/audit_retention_legal_hold.rs:109`
- `services/analysis-worker/src/analysis_agent_jobs.rs:410,431`

# 이벤트 계약 명세

## 1. 목적과 적용 범위

구린네의 수집, 정규화, 탐지, 조사, 검토, 공개, 정정 흐름은 장시간 실행되고 일부 단계가 재시도된다. 이 문서는 서비스 사이에서 전달되는 이벤트의 의미, 스키마, 멱등성, 순서, 재처리, 개인정보 및 증거 보존 규칙을 고정한다. 이벤트는 업무 상태의 유일한 원장이 아니다. PostgreSQL의 도메인 테이블과 append-only 감사 로그가 권위 있는 상태이며, 이벤트는 그 상태 변경을 알리는 내구성 있는 전달 수단이다.

이벤트 생산자는 도메인 상태와 outbox 레코드를 같은 데이터베이스 트랜잭션으로 기록한다. 소비자는 이벤트를 처리한 사실을 inbox 또는 consumer-offset 테이블에 기록한다. “적어도 한 번(at-least-once)” 전달을 전제로 하며 모든 소비자는 중복 이벤트를 안전하게 무시하거나 동일한 결과로 수렴해야 한다.

## 2. 공통 envelope

모든 이벤트는 `specs/schemas/event-envelope.schema.json`을 통과해야 한다. 최소 필드는 다음과 같다.

```json
{
  "event_id": "evt_01j2example000000000000001",
  "event_type": "source.document.stored.v1",
  "event_version": 1,
  "occurred_at": "2026-01-15T03:10:00Z",
  "recorded_at": "2026-01-15T03:10:01Z",
  "aggregate_type": "SOURCE_DOCUMENT",
  "aggregate_id": "srcdoc_fixture_price_target",
  "aggregate_version": 1,
  "producer": {
    "service": "worker",
    "instance_id": "worker_fixture_01"
  },
  "correlation_id": "corr_ingestion_fixture_001",
  "causation_id": "evt_01j2example000000000000000",
  "idempotency_key": "pps_g2b_contracts:fixture-contract-001:v1",
  "classification": "INTERNAL",
  "trace_id": "0123456789abcdef0123456789abcdef",
  "payload": {}
}
```

### 2.1 식별자

- `event_id`: 전역 유일하며 재전송 때 바뀌지 않는다.
- `correlation_id`: 하나의 수집 실행, 조사 workflow 또는 publication saga를 묶는다.
- `causation_id`: 직접 원인이 된 이벤트 ID다. cron이나 사람 명령처럼 원인 이벤트가 없으면 `null`을 허용한다.
- `idempotency_key`: 업무 의미상 같은 동작을 식별한다. 형식은 이벤트별로 아래에 정의한다.
- `aggregate_version`: 같은 aggregate의 낙관적 잠금 버전이다. 역행 이벤트는 projection을 덮어쓰지 않는다.

### 2.2 분류

| 값 | 의미 | payload 제한 |
|---|---|---|
| `PUBLIC` | 공개 read model로 전달 가능한 정보 | 공개 승인된 필드만 |
| `INTERNAL` | 운영 및 조사 내부 정보 | 최소 필요 정보만 |
| `RESTRICTED` | 비공개 소명, 법률 검토, 제보자 위험 | 암호화·권한·짧은 log retention |
| `SECURITY` | 악성 파일, 권한 위반, kill switch | 원문 콘텐츠를 로그에 복제하지 않음 |

이벤트 버스, 로그, APM에는 raw document bytes, 전체 주민등록번호, 인증 token, 비공개 소명 첨부, 제보자 신원, 모델 provider secret을 넣지 않는다. payload가 원본을 필요로 하면 object ID와 hash만 넣는다.

## 3. 버전 관리와 호환성

이벤트 이름 끝의 `v1`은 payload의 major version이다. 하위 호환 변경은 같은 major에서 허용한다.

허용:

- optional field 추가
- enum을 소비자가 unknown-safe하게 처리하도록 설계한 경우 enum 값 추가
- 설명 또는 validation 상한 완화

금지:

- 필수 필드 제거 또는 이름 변경
- 의미 변경
- 숫자의 단위 변경
- 식별자 의미 변경
- 기존 enum 값의 의미 재사용

호환 불가능한 변경은 새 이벤트 이름(`...v2`)과 병행 발행 기간을 둔다. 소비자가 알 수 없는 major version을 받으면 ACK하지 말고 schema-dead-letter로 보낸다.

## 4. 순서와 중복 규칙

- 전역 순서는 보장하지 않는다.
- aggregate 내부에서는 `aggregate_version`으로 순서를 판정한다.
- version이 현재보다 작거나 같고 event ID가 이미 처리되었으면 no-op 처리한다.
- version gap이 발견되면 즉시 상태를 추정하지 않는다. aggregate 원장을 다시 읽어 projection을 재구축한다.
- 동일 `idempotency_key`로 다른 payload hash가 들어오면 `idempotency.conflict.detected.v1` 보안 이벤트를 만든다.
- 소비자 실패는 지수 backoff와 jitter를 적용한다. 영구 오류는 dead-letter 뒤 운영자 조치 없이는 자동 무한 재시도하지 않는다.

## 5. 원본 수집 이벤트

### 5.1 `source.fetch.requested.v1`

수집 scheduler 또는 운영자가 특정 source page/object 수집을 요청한다.

필수 payload:

```json
{
  "source_id": "PPS_G2B_CONTRACTS",
  "request_kind": "INCREMENTAL",
  "cursor": null,
  "window": {
    "from": "2026-01-14T00:00:00Z",
    "to": "2026-01-15T00:00:00Z"
  },
  "priority": 50,
  "policy_version": "source-policy-1.0.0"
}
```

- `request_kind`: `INCREMENTAL`, `BACKFILL`, `RECONCILIATION`, `MANUAL_REPLAY`
- idempotency: `source_id:request_kind:window.from:window.to:cursor`
- source가 `PAUSED`, `LEGAL_HOLD`, `KILL_SWITCHED`이면 fetcher는 실행하지 않고 거절 이벤트를 남긴다.

### 5.2 `source.fetch.completed.v1`

```json
{
  "source_id": "PPS_G2B_CONTRACTS",
  "fetch_attempt_id": "fetch_fixture_001",
  "http_status": 200,
  "object_count": 100,
  "byte_count": 48123,
  "next_cursor": "page:2",
  "rate_limit": {
    "remaining": 950,
    "reset_at": null
  }
}
```

HTTP body는 이벤트에 넣지 않는다.

### 5.3 `source.fetch.failed.v1`

```json
{
  "source_id": "PPS_G2B_CONTRACTS",
  "fetch_attempt_id": "fetch_fixture_001",
  "failure_category": "UPSTREAM_UNAVAILABLE",
  "retryable": true,
  "status_code": 503,
  "safe_message": "upstream returned 503",
  "next_retry_not_before": "2026-01-15T03:20:00Z"
}
```

`failure_category`: `AUTHENTICATION`, `AUTHORIZATION`, `RATE_LIMIT`, `UPSTREAM_UNAVAILABLE`, `NETWORK`, `MALFORMED_RESPONSE`, `POLICY_BLOCKED`, `UNKNOWN`.

### 5.4 `source.document.stored.v1`

원본 bytes가 object storage에 먼저 내구적으로 기록되고 hash 검증까지 끝난 뒤 발행한다.

```json
{
  "source_document_id": "srcdoc_fixture_price_target",
  "source_id": "PPS_G2B_CONTRACTS",
  "remote_record_id": "fixture-contract-001",
  "remote_version": "v1",
  "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "raw_object_id": "raw_fixture_price_target",
  "mime_detected": "application/json",
  "storage_class": "RAW_PRIVATE",
  "retrieved_at": "2026-01-15T03:10:00Z"
}
```

idempotency: `source_id:remote_record_id:remote_version:content_sha256`.

### 5.5 `source.document.duplicate_observed.v1`

같은 content hash와 canonical remote identity가 이미 있을 때 저장 중복을 알린다. 중복은 정상 흐름이며 alert가 아니다.

### 5.6 `source.schema.drift.detected.v1`

```json
{
  "source_id": "PPS_G2B_CONTRACTS",
  "source_document_id": "srcdoc_fixture_schema_drift",
  "expected_fingerprint": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "observed_fingerprint": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
  "change_class": "BREAKING",
  "unknown_paths": ["$.items[0].newAmountObject"],
  "missing_required_paths": ["$.items[0].contractAmount"],
  "quarantined": true
}
```

breaking drift가 발생하면 해당 source의 신규 normalization을 fail-closed로 멈추고 이전 정상 데이터는 stale marker와 함께 유지한다.

## 6. 안전 검사와 파싱 이벤트

### 6.1 `raw_object.scan.completed.v1`

```json
{
  "raw_object_id": "raw_fixture_price_target",
  "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "malware_scan_status": "CLEAN",
  "archive_bomb_detected": false,
  "active_content_detected": false,
  "sanitizer_version": "sanitizer-1.0.0"
}
```

### 6.2 `raw_object.quarantined.v1`

`INFECTED`, archive bomb, parser sandbox escape 의심, MIME 불일치 등. 원본은 격리되고 자동 파싱하지 않는다.

### 6.3 `source.document.parsed.v1`

```json
{
  "source_document_id": "srcdoc_fixture_price_target",
  "parser_name": "g2b-contract-json",
  "parser_version": "1.0.0",
  "parse_result_id": "parse_fixture_price_target_v1",
  "record_count": 1,
  "warning_codes": [],
  "parse_output_hash": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
}
```

### 6.4 `source.document.parse_failed.v1`

실패 category: `UNSUPPORTED_MIME`, `SCHEMA_MISMATCH`, `ENCODING`, `RESOURCE_LIMIT`, `MALFORMED`, `SANDBOX`, `UNKNOWN`. LLM을 사용해 임의 복구하지 않는다. parser 버전과 원본 hash를 기록한다.

## 7. 정규화 및 entity resolution 이벤트

### 7.1 `contract.normalized.v1`

```json
{
  "contract_id": "contract_fixture_price_target",
  "source_document_ids": ["srcdoc_fixture_price_target"],
  "normalization_version": "1.0.0",
  "normalized_record_hash": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
  "identity_status": {
    "agency": "VERIFIED",
    "supplier": "VERIFIED"
  },
  "warning_codes": []
}
```

idempotency: `sorted_source_document_hashes:normalization_version`.

### 7.2 `contract.normalization.blocked.v1`

필수 금액, 날짜, 기관 식별, 품목 단위 등이 안전하게 해석되지 않을 때 발생한다. `guessed_value`를 만들어서는 안 된다.

### 7.3 `entity.resolution.proposed.v1`

자동 merge가 아니라 후보 제안이다.

```json
{
  "entity_type": "SUPPLIER",
  "source_entity_id": "supplier_candidate_01",
  "candidate_entity_id": "supplier_fixture_alpha",
  "confidence": 0.87,
  "features": ["normalized_name", "business_number_last4"],
  "automatic_merge_allowed": false
}
```

### 7.4 `entity.resolution.confirmed.v1`

검증 가능한 authoritative identifier 또는 사람 승인을 근거로 확정한다. merge provenance와 actor를 payload에 포함한다.

### 7.5 `entity.resolution.reverted.v1`

잘못된 merge를 되돌린다. 기존 사건·출판물의 영향 평가 job을 반드시 촉발한다.

## 8. 탐지 이벤트

### 8.1 `detection.run.requested.v1`

```json
{
  "rule_key": "PRICE_OUTLIER",
  "rule_version": "1.0.0",
  "scope": {
    "type": "CONTRACT",
    "ids": ["contract_fixture_price_target"]
  },
  "input_cutoff_at": "2026-01-15T03:30:00Z",
  "budget_class": "DETERMINISTIC"
}
```

같은 input cutoff, rule version, input IDs로 결과가 재현돼야 한다.

### 8.2 `anomaly.signal.created.v1`

payload는 `anomaly-signal.schema.json`의 객체 전체 또는 immutable object reference와 hash를 포함한다. 신호는 의혹 제기나 공개가 아니다.

### 8.3 `anomaly.signal.blocked.v1`

규칙 threshold는 넘었지만 비교 불가능성, VAT 불명, bundle 불명, identity ambiguity 등 blocker가 있는 경우다. blocker가 해소되기 전 사건 자동 생성 또는 공개 후보 승격 금지다.

### 8.4 `anomaly.signal.dismissed.v1`

dismissal reason code와 사람/결정적 규칙 actor를 포함한다. 모델 단독 dismissal은 허용하지 않는다.

### 8.5 `anomaly.signal.attached_to_case.v1`

한 신호가 사건에 연결됐음을 나타낸다. 동일 신호가 서로 모순되는 활성 사건에 중복 연결되지 않도록 DB 제약을 둔다.

## 9. 사건 lifecycle 이벤트

### 9.1 `case.created.v1`

```json
{
  "case_id": "case_fixture_price_target",
  "case_number": "GRN-2026-000001",
  "initial_state": "SIGNAL_DETECTED",
  "signal_ids": ["signal_fixture_price_target"],
  "risk_level": "MEDIUM",
  "policy_version": "editorial-1.0.0"
}
```

### 9.2 `case.transitioned.v1`

```json
{
  "case_id": "case_fixture_price_target",
  "from_state": "INVESTIGATING",
  "to_state": "AWAITING_RESPONSE",
  "case_version_before": 6,
  "case_version_after": 7,
  "transition_reason": "minimum evidence package assembled",
  "actor": {
    "actor_type": "HUMAN",
    "actor_id": "editor_fixture_01"
  },
  "policy_checks": [
    {"check": "subject_identity_verified", "result": "PASS"},
    {"check": "claim_evidence_complete", "result": "PASS"}
  ]
}
```

허용 상태 전이는 `docs/04-case-lifecycle.md`의 테이블이 권위 있다. expected version 불일치는 409 conflict로 실패하며 이벤트를 발행하지 않는다.

### 9.3 `case.assignment.changed.v1`

소유자 변경, recusal, conflict-of-interest flag를 기록한다.

### 9.4 `case.evidence.added.v1`

Evidence 전체를 이벤트에 복제하지 않고 `evidence_id`, `evidence_hash`, `stance`, `tier`, `verification_status`를 전달한다.

### 9.5 `case.claim.changed.v1`

claim revision ID, 이전 hash, 새 hash, evidence refs를 기록한다. 공개된 claim을 조용히 overwrite하지 않는다.

### 9.6 `case.reopened.v1`

새 증거, 정정 요청, entity split, source correction 때문에 종료 사건을 재개한다. 이전 종료 사유와 trigger를 포함한다.

## 10. 에이전트 작업 이벤트

### 10.1 `agent.task.requested.v1`

```json
{
  "agent_task_id": "agtask_fixture_001",
  "case_id": "case_fixture_price_target",
  "agent_role": "SKEPTIC",
  "input_snapshot_hash": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
  "allowed_tool_classes": ["INTERNAL_READ", "APPROVED_WEB_READ"],
  "allowed_domains": ["example.invalid"],
  "max_input_tokens": 30000,
  "max_output_tokens": 6000,
  "max_cost_microunits": 200000,
  "deadline_at": "2026-01-15T04:30:00Z",
  "output_schema": "skeptic-report.v1"
}
```

### 10.2 `agent.task.completed.v1`

출력은 schema 검증 후에만 completed로 기록한다. 다음을 포함한다.

- model provider/model identifier
- prompt template version
- tool-call manifest hash
- input snapshot hash
- output object ID/hash
- token/cost accounting
- unsupported citation count
- policy warnings

### 10.3 `agent.task.rejected.v1`

schema failure, citation mismatch, prompt injection policy hit, budget 초과, prohibited tool request는 rejected다. 자동으로 raw free-form text를 상태에 반영하지 않는다.

### 10.4 `agent.prompt_injection.detected.v1`

```json
{
  "agent_task_id": "agtask_fixture_injection",
  "source_document_id": "srcdoc_fixture_prompt_injection",
  "detection_method": "CONTENT_POLICY_PATTERN_AND_TOOL_INTENT",
  "safe_excerpt_hash": "1111111111111111111111111111111111111111111111111111111111111111",
  "requested_effect": "IGNORE_POLICY_AND_PUBLISH",
  "action": "CONTENT_TREATED_AS_DATA"
}
```

원문의 공격 문구를 일반 운영 로그에 그대로 복제하지 않는다.

## 11. 소명과 제보 이벤트

### 11.1 `response.request.issued.v1`

```json
{
  "response_request_id": "resp_req_fixture_001",
  "case_id": "case_fixture_price_target",
  "party_type": "AGENCY",
  "party_display_name": "가상새빛시청",
  "requested_topics": ["bundle_components", "maintenance_scope", "unit_price_basis"],
  "issued_at": "2026-01-20T00:00:00Z",
  "deadline_at": "2026-01-27T00:00:00Z",
  "token_id": "response_token_fixture_001"
}
```

토큰 원문은 이벤트에 넣지 않는다.

### 11.2 `response.submitted.v1`

비공개 분류다. 본문 hash, attachment object IDs, malware scan 상태, 제출 시각만 이벤트에 넣고 full body는 권한이 제한된 저장소에 둔다.

### 11.3 `response.verified.v1`

도메인 또는 공식 연락처 확인, 서명 검증 등 제출 주체 확인 상태를 기록한다. 검증이 안 됐다는 이유만으로 내용을 삭제하지 않되 공개 표시에 분명히 반영한다.

### 11.4 `response.deadline.expired.v1`

“응답하지 않았다”는 사실만 기록하며 “반박하지 못했다” 또는 “인정했다”로 해석하지 않는다.

## 12. 검토 및 공개 이벤트

### 12.1 `review.snapshot.created.v1`

검토 대상의 immutable snapshot hash를 만든다. 사건, claims, evidence, responses, methodology, source freshness를 포함한 canonical serialization hash다.

### 12.2 `review.decision.recorded.v1`

`review-decision.schema.json`을 따른다. 승인 결정은 snapshot hash에만 유효하다. snapshot 내용이 바뀌면 기존 승인은 stale 처리한다.

### 12.3 `publication.requested.v1`

```json
{
  "case_id": "case_fixture_price_target",
  "review_snapshot_hash": "2222222222222222222222222222222222222222222222222222222222222222",
  "target_display_status": "PUBLISHED_ANOMALY",
  "expected_case_version": 12,
  "required_editor_approvals": 1,
  "legal_review_required": false,
  "policy_version": "editorial-1.0.0"
}
```

### 12.4 `publication.blocked.v1`

block codes:

- `MISSING_HUMAN_APPROVAL`
- `STALE_REVIEW_SNAPSHOT`
- `MISSING_EVIDENCE`
- `UNVERIFIED_SUBJECT_IDENTITY`
- `UNRESOLVED_BLOCKING_CONDITION`
- `RESPONSE_WINDOW_INCOMPLETE`
- `LEGAL_REVIEW_REQUIRED`
- `PROHIBITED_LANGUAGE`
- `SOURCE_LICENSE_BLOCKED`
- `SOURCE_FRESHNESS_BLOCKED`
- `POLICY_VERSION_MISMATCH`
- `KILL_SWITCH_ACTIVE`

### 12.5 `publication.revision.committed.v1`

publication revision이 DB와 immutable object에 기록된 뒤 발생한다. payload에는 revision ID, content hash, review snapshot hash, public read model version이 들어간다.

### 12.6 `publication.read_model.updated.v1`

public API projection이 새 revision을 제공할 준비가 된 뒤 발행한다. CDN purge와 sitemap update는 이 이벤트를 소비한다.

### 12.7 `publication.correction.requested.v1`

정정 요청 접수는 원 게시물을 즉시 삭제하라는 명령이 아니다. 위험도 triage와 임시 notice 정책을 시작한다.

### 12.8 `publication.corrected.v1`

새 revision ID, superseded revision ID, correction severity, reason code, public notice를 포함한다. 이전 revision은 내부 감사 및 법적 보존 정책에 따라 유지한다.

### 12.9 `publication.retracted.v1`

retraction도 tombstone이 아니라 새 공개 revision이다. original URL은 철회 notice를 반환하고 무단 404로 사라지지 않는다. 긴급 법적 명령은 별도 policy event로 처리한다.

## 13. 운영·보안 이벤트

### 13.1 `budget.threshold.reached.v1`

일·월·workflow별 70%, 90%, 100% threshold를 기록한다. 100%에서는 비필수 LLM task를 fail-closed로 중단한다.

### 13.2 `kill_switch.changed.v1`

scope: `ALL_PUBLICATION`, `SOURCE`, `MODEL_PROVIDER`, `AGENT_TOOL_CLASS`, `PUBLIC_WRITE`, `ATTACHMENT_PROCESSING`. 사람 두 명 승인 또는 incident commander + 사후 검토가 필요한 범위를 정책에서 정의한다.

### 13.3 `authorization.denied.v1`

actor, action, resource class, reason code만 기록한다. secret/token/full payload는 기록하지 않는다.

### 13.4 `idempotency.conflict.detected.v1`

같은 key에 다른 요청 hash가 관측된 경우다. 해당 mutation은 적용하지 않는다.

### 13.5 `audit.integrity.check.failed.v1`

append-only audit chain 또는 object hash가 맞지 않을 때 발생한다. severity는 critical이며 publication write를 자동 중단할 수 있다.

## 14. 재처리와 replay

재처리는 다음 원칙을 지킨다.

1. raw bytes는 바꾸지 않는다.
2. parser/normalizer/rule version을 명시한다.
3. 과거 결과를 overwrite하지 않고 새 version으로 계산한다.
4. 기존 publication은 자동 갱신하지 않는다.
5. 결과 차이는 impact report를 생성한다.
6. published case에 material difference가 있으면 correction review를 연다.
7. replay actor와 reason을 감사 로그에 남긴다.

`MANUAL_REPLAY`는 운영자 승인, 대상 범위, dry-run 결과, 비용 예산, rollback plan이 있어야 한다.

## 15. Dead-letter 정책

dead-letter record 필수 필드:

- original event ID/type/version
- consumer name/version
- first/last failed time
- attempt count
- normalized failure category
- safe error message
- payload hash
- classification
- next action: `AUTO_RETRY`, `OPERATOR_REVIEW`, `SCHEMA_MIGRATION`, `DISCARD_DUPLICATE`, `SECURITY_REVIEW`

restricted payload는 DLQ UI에 전체 표시하지 않는다. 운영자는 원본 권한 확인 뒤 별도 secure viewer로 연다.

## 16. 관측성 지표

이벤트별 최소 지표:

- produced/consumed count
- end-to-end lag
- retry count
- dead-letter count
- duplicate count
- version-gap count
- schema rejection count
- idempotency conflict count
- classification별 event volume

고유 agency/supplier 이름을 metric label로 사용하지 않는다. cardinality와 개인정보 노출을 막기 위해 source ID, event type, result code 등 bounded labels만 쓴다.

## 17. 계약 테스트

각 생산자/소비자 조합은 다음을 자동 검증한다.

1. current schema의 최소 payload 수용
2. optional unknown field를 소비자가 안전하게 무시하거나 validation layer가 정책대로 처리
3. 같은 event 재전달의 no-op 또는 동일 결과
4. aggregate version 역행 방지
5. version gap reconciliation
6. malformed payload DLQ
7. restricted payload의 로그 redaction
8. idempotency key 충돌 차단
9. outbox transaction rollback 시 이벤트 미발행
10. 소비 후 crash와 재전달에서 side effect 중복 없음
11. event replay가 publication을 자동 수정하지 않음
12. kill switch가 publication event consumer에서 강제됨

## 18. 변경 승인

이 문서 또는 event schema 변경은 다음의 승인을 필요로 한다.

- 파이프라인 owner
- 영향을 받는 consumer owner
- domain model owner
- restricted/security event면 security owner
- publication 관련 이벤트면 editorial policy owner

변경 PR에는 compatibility classification, migration 순서, dual-publish 기간, replay 영향, rollback, consumer contract-test 결과를 포함한다.

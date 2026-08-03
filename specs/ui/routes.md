# 최종 Route / Screen Index

상태: **FINAL**

총 95개 화면을 한 번의 최종 구현에서 모두 제공한다.

## Public Web — 35개

| ID | Route | 화면 | Access | Archetype |
|---|---|---|---|---|
| `PUB-001` | `/` | 홈 | `anonymous` | `EVIDENCE_LANDING` |
| `PUB-002` | `/search` | 통합 검색 | `anonymous` | `SEARCH_INDEX` |
| `PUB-003` | `/cases` | 공개 사례 | `anonymous` | `SEARCH_INDEX` |
| `PUB-004` | `/cases/{caseSlug}` | 사건 상세 | `anonymous` | `EVIDENCE_LANDING` |
| `PUB-005` | `/cases/{caseSlug}/revisions/{revision}` | 사건 공개 개정본 | `anonymous` | `EVIDENCE_LANDING` |
| `PUB-006` | `/cases/{caseSlug}/reproduce` | 계산 재현 | `anonymous` | `ENTITY_DETAIL` |
| `PUB-007` | `/agencies` | 기관 | `anonymous` | `SEARCH_INDEX` |
| `PUB-008` | `/agencies/{agencySlug}` | 기관 상세 | `anonymous` | `ENTITY_DETAIL` |
| `PUB-009` | `/suppliers` | 업체 | `anonymous` | `SEARCH_INDEX` |
| `PUB-010` | `/suppliers/{supplierSlug}` | 업체 상세 | `anonymous` | `ENTITY_DETAIL` |
| `PUB-011` | `/contracts` | 계약 | `anonymous` | `SEARCH_INDEX` |
| `PUB-012` | `/contracts/{contractId}` | 계약 상세 | `anonymous` | `EVIDENCE_LANDING` |
| `PUB-013` | `/methodology` | 방법론 | `anonymous` | `POLICY` |
| `PUB-014` | `/methodology/rules/{ruleId}` | 탐지 규칙 상세 | `anonymous` | `ENTITY_DETAIL` |
| `PUB-015` | `/coverage` | 데이터 범위 | `anonymous` | `POLICY` |
| `PUB-016` | `/sources` | 데이터 출처 | `anonymous` | `SEARCH_INDEX` |
| `PUB-017` | `/sources/{sourceId}` | 데이터 출처 상세 | `anonymous` | `ENTITY_DETAIL` |
| `PUB-018` | `/corrections` | 정정·철회 | `anonymous` | `SEARCH_INDEX` |
| `PUB-019` | `/corrections/{correctionId}` | 정정 상세 | `anonymous` | `EVIDENCE_LANDING` |
| `PUB-020` | `/data` | 데이터·다운로드 | `anonymous` | `POLICY` |
| `PUB-021` | `/api` | 공개 API 문서 | `anonymous` | `POLICY` |
| `PUB-022` | `/about` | 소개 | `anonymous` | `POLICY` |
| `PUB-023` | `/about/funding` | 재원·수익 투명성 | `anonymous` | `POLICY` |
| `PUB-024` | `/about/governance` | 운영·거버넌스 | `anonymous` | `POLICY` |
| `PUB-025` | `/editorial-policy` | 편집·공개 정책 | `anonymous` | `POLICY` |
| `PUB-026` | `/contact` | 문의 | `anonymous` | `GUIDED_FORM` |
| `PUB-027` | `/correction-request` | 정정 요청 | `anonymous` | `GUIDED_FORM` |
| `PUB-028` | `/correction-request/receipt` | 정정 요청 접수 | `receipt-token` | `GUIDED_FORM` |
| `PUB-029` | `/subscribe` | 업데이트 구독 | `anonymous` | `GUIDED_FORM` |
| `PUB-030` | `/subscription/manage` | 구독 관리 | `magic-link` | `GUIDED_FORM` |
| `PUB-031` | `/privacy` | 개인정보 처리방침 | `anonymous` | `POLICY` |
| `PUB-032` | `/terms` | 이용약관 | `anonymous` | `POLICY` |
| `PUB-033` | `/accessibility` | 접근성 안내 | `anonymous` | `POLICY` |
| `PUB-034` | `/{systemPath}` | 오류·시스템 상태 | `anonymous` | `AUTH_SYSTEM` |
| `PUB-035` | `/donate` | 후원 | `anonymous` | `GUIDED_FORM` |

PUB-028과 PUB-030의 일회용 token은 exchange 요청 입력으로만 사용한다. 교환 성공과 실패 모두 위 token-free canonical URL로 이동하며 URL에 token을 남기지 않는다.

## Response Portal — 8개

| ID | Route | 화면 | Access | Archetype |
|---|---|---|---|---|
| `RSP-001` | `/respond/{token}` | 소명 요청 확인 | `response-token` | `GUIDED_FORM` |
| `RSP-002` | `/respond/{token}/overview` | 요청 내용 | `response-token` | `GUIDED_FORM` |
| `RSP-003` | `/respond/{token}/answer` | 답변 작성 | `response-token` | `GUIDED_FORM` |
| `RSP-004` | `/respond/{token}/attachments` | 첨부자료 | `response-token` | `GUIDED_FORM` |
| `RSP-005` | `/respond/{token}/review` | 제출 전 확인 | `response-token` | `GUIDED_FORM` |
| `RSP-006` | `/respond/{token}/receipt` | 소명 접수 영수증 | `response-token` | `GUIDED_FORM` |
| `RSP-007` | `/respond/{token}/extension` | 기한 연장 요청 | `response-token` | `GUIDED_FORM` |
| `RSP-008` | `/respond/unavailable` | 요청에 접근할 수 없음 | `anonymous` | `AUTH_SYSTEM` |

## Review Console — 52개

| ID | Route | 화면 | Access | Archetype |
|---|---|---|---|---|
| `AUTH-001` | `/auth/sign-in` | 직원 로그인 | `anonymous` | `AUTH_SYSTEM` |
| `AUTH-002` | `/auth/verify` | MFA·재인증 | `authenticated` | `AUTH_SYSTEM` |
| `AUTH-003` | `/auth/access-denied` | 접근 권한 없음 | `authenticated` | `AUTH_SYSTEM` |
| `AUTH-004` | `/auth/session-expired` | 세션 만료 | `anonymous` | `AUTH_SYSTEM` |
| `INT-001` | `/internal/dashboard` | 운영 대시보드 | `oidc` | `OPERATIONS` |
| `INT-002` | `/internal/my-work` | 내 작업 | `oidc` | `QUEUE` |
| `INT-003` | `/internal/search` | 내부 검색 | `oidc` | `SEARCH_INDEX` |
| `INT-004` | `/internal/notifications` | 알림 | `oidc` | `QUEUE` |
| `SIG-001` | `/internal/signals` | 신호 대기열 | `oidc` | `QUEUE` |
| `SIG-002` | `/internal/signals/{signalId}` | 신호 검토 | `oidc` | `DECISION_REVIEW` |
| `CAS-001` | `/internal/cases` | 사건 대기열 | `oidc` | `QUEUE` |
| `CAS-002` | `/internal/cases/{caseId}/overview` | 사건 개요 | `oidc` | `WORKSPACE` |
| `CAS-003` | `/internal/cases/{caseId}/signals` | 연결된 신호 | `oidc` | `WORKSPACE` |
| `CAS-004` | `/internal/cases/{caseId}/evidence` | 근거 | `oidc` | `WORKSPACE` |
| `CAS-005` | `/internal/cases/{caseId}/evidence/{evidenceId}` | 근거 검증 | `oidc` | `WORKSPACE` |
| `CAS-006` | `/internal/cases/{caseId}/claims` | 공개 주장 작성 | `oidc` | `WORKSPACE` |
| `CAS-007` | `/internal/cases/{caseId}/hypotheses` | 조사 가설 | `oidc` | `WORKSPACE` |
| `CAS-008` | `/internal/cases/{caseId}/responses` | 소명 관리 | `oidc` | `WORKSPACE` |
| `CAS-009` | `/internal/cases/{caseId}/responses/new` | 소명 요청 작성 | `oidc` | `GUIDED_FORM` |
| `CAS-010` | `/internal/cases/{caseId}/agent-runs` | 에이전트 실행 | `oidc` | `WORKSPACE` |
| `CAS-011` | `/internal/cases/{caseId}/agent-runs/{runId}` | 에이전트 실행 상세 | `oidc` | `WORKSPACE` |
| `CAS-012` | `/internal/cases/{caseId}/timeline` | 사건 타임라인 | `oidc` | `WORKSPACE` |
| `CAS-013` | `/internal/cases/{caseId}/review` | 검토 준비도 | `oidc` | `WORKSPACE` |
| `CAS-014` | `/internal/cases/{caseId}/preview` | 공개 미리보기 | `oidc` | `WORKSPACE` |
| `CAS-015` | `/internal/cases/{caseId}/corrections` | 사건 정정·철회 | `oidc` | `WORKSPACE` |
| `CAS-016` | `/internal/cases/{caseId}/audit` | 사건 감사 | `oidc` | `WORKSPACE` |
| `REV-001` | `/internal/review` | 검토 대기열 | `oidc` | `QUEUE` |
| `REV-002` | `/internal/review/{snapshotId}` | 독립 스냅샷 검토 | `oidc` | `DECISION_REVIEW` |
| `REV-003` | `/internal/review/{snapshotId}/publish` | 게시 확인·영수증 | `oidc` | `DECISION_REVIEW` |
| `COR-001` | `/internal/corrections` | 정정 대기열 | `oidc` | `QUEUE` |
| `COR-002` | `/internal/corrections/{correctionId}` | 정정 작업공간 | `oidc` | `WORKSPACE` |
| `SRC-001` | `/internal/sources` | 출처 등록부 | `oidc` | `OPERATIONS` |
| `SRC-002` | `/internal/sources/{sourceId}` | 출처 상세 | `oidc` | `OPERATIONS` |
| `SRC-003` | `/internal/sources/{sourceId}/runs` | 출처 실행 기록 | `oidc` | `QUEUE` |
| `SRC-004` | `/internal/sources/{sourceId}/runs/{runId}` | 출처 실행 상세 | `oidc` | `OPERATIONS` |
| `SRC-005` | `/internal/sources/{sourceId}/schema-drift` | 스키마 드리프트 | `oidc` | `DECISION_REVIEW` |
| `SRC-006` | `/internal/sources/{sourceId}/backfill` | 백필·재실행 | `oidc` | `DECISION_REVIEW` |
| `RULE-001` | `/internal/rules` | 탐지 규칙 등록부 | `oidc` | `SEARCH_INDEX` |
| `RULE-002` | `/internal/rules/{ruleId}/versions/{version}` | 규칙 버전 상세 | `oidc` | `ENTITY_DETAIL` |
| `RULE-003` | `/internal/rules/{ruleId}/versions/{version}/evaluation` | 규칙 평가·섀도 실행 | `oidc` | `OPERATIONS` |
| `RULE-004` | `/internal/rules/{ruleId}/versions/{version}/activation` | 규칙 활성화 | `oidc` | `DECISION_REVIEW` |
| `OPS-001` | `/internal/operations` | 운영 개요 | `oidc` | `OPERATIONS` |
| `OPS-002` | `/internal/operations/jobs` | 작업 대기열·DLQ | `oidc` | `QUEUE` |
| `OPS-003` | `/internal/operations/jobs/{jobId}` | 작업 상세 | `oidc` | `OPERATIONS` |
| `OPS-004` | `/internal/operations/budgets` | 비용·예산 | `oidc` | `OPERATIONS` |
| `OPS-005` | `/internal/operations/providers` | 외부 공급자 상태 | `oidc` | `OPERATIONS` |
| `OPS-006` | `/internal/operations/kill-switches` | 킬 스위치 | `oidc` | `DECISION_REVIEW` |
| `AUD-001` | `/internal/audit` | 감사 로그 탐색기 | `oidc` | `SEARCH_INDEX` |
| `ADM-001` | `/internal/admin/users` | 사용자·접근 관리 | `oidc` | `SEARCH_INDEX` |
| `ADM-002` | `/internal/admin/users/{userId}` | 사용자 상세·역할 | `oidc` | `DECISION_REVIEW` |
| `ADM-003` | `/internal/admin/roles` | 역할 정의 | `oidc` | `ENTITY_DETAIL` |
| `ACC-001` | `/internal/account` | 내 계정·세션 | `oidc` | `ENTITY_DETAIL` |

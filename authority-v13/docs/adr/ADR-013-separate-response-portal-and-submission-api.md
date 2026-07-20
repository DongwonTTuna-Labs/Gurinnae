# ADR-013: Response Portal과 Submission API 분리

- 상태: Accepted
- 날짜: 2026-07-10
- 대체/수정 대상: v2.1 Control API에 포함된 외부 response endpoint
- 관련: `docs/30-product-surface-boundaries.md`

## Context

v2.1 baseline은 외부 response token endpoint를 내부 Control API와 같은 계약에 포함했다. 내부 OIDC/RBAC command와 외부 token-scoped submission은 인증, rate limit, 데이터 노출, client distribution, CSP, 운영 위험이 다르다.

## Decision

다음을 독립 surface로 추가한다.

```text
apps/response-portal
services/submission-api
packages/api-client-submission
specs/api/submission-api.design-baseline.openapi.yaml
specs/generated/submission-api.openapi.json
```

Control API의 `/v1/responses/{token}` operation은 제거하고 Submission API로 이동한다.

Submission API가 담당한다.

- response request 조회
- draft 저장
- attachment lifecycle
- response 제출
- extension request
- correction request
- subscription verify/manage

Submission API는 publication을 직접 변경할 수 없다. immutable intake record와 outbox event를 만든 뒤 내부 사람이 처리한다.

## Trust boundary

- Response Portal: 별도 origin, no-store, noindex, no-referrer, 엄격한 CSP
- Public Web: correction/subscription을 server action으로 Submission API에 전달
- Submission client: server-only
- DB role: `gurine_submission_api`
- 다른 case 탐색 또는 내부 editorial data 접근 금지

## Consequences

장점:

- 외부 입력과 내부 command 격리
- generated client leakage 방지
- rate limit/upload 정책 독립
- response portal security headers 명확

비용:

- 서비스와 배포 단위 증가
- OpenAPI/client 3개 관리
- external intake projection 필요
- end-to-end test 증가

## Rejected alternatives

- Control API에 token endpoint 유지
- Public API에 POST 추가
- Response Portal이 Control API에 직접 접근
- 단일 combined OpenAPI/client

## Fitness tests

- Control OpenAPI에 response token route 없음
- Submission API DB role이 editorial/publication write 권한 없음
- response portal/client bundle에 control client 없음
- public browser bundle에 submission credential 없음
- token으로 다른 request 조회 불가
- submission 후 publication state 불변

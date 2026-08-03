# 최종 API·화면 데이터 준비도

상태: **ALL CONTRACTS READY / v13.0.0**

| Surface | Operation 수 | 상태 |
|---|---:|---|
| Public API | 41 | READY |
| Submission API | 34 | READY |
| Control API | 131 | READY |
| Identity/BFF | 6 | READY |
| 합계 | 212 | READY |

각 operation은 `specs/api/operation-contracts.yaml`에서 exact method, path, kind, auth, capability, request/response schema, success status, error mapping, idempotency, optimistic concurrency, audit와 consuming screen을 가진다.

- Query: 107
- Command: 105
- HTTP non-GET command: 102
- 외부 네 OpenAPI의 operationId는 전역 고유하며 private identity service OpenAPI는 별도 namespace와 service-assertion 경계를 갖는다.
- 모든 screen requirement와 action은 operation 또는 명시적 local-only/navigation 계약을 가진다.
- Public, Submission, Control, Identity 계약은 서로 다른 security scheme과 runtime boundary를 사용한다.

완성 source에서는 212개 operation handler, application use case, persistence mapping, integration/contract test가 모두 존재해야 한다.

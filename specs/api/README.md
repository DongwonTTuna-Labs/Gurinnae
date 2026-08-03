# Final API Contracts v13.0.0

상태: **FINAL**

## API surfaces

| API | Operation | 역할 | 호출자 | Generated client |
|---|---:|---|---|---|
| Public API | 41 | 승인된 public projection과 정적 정책 콘텐츠 조회 | Public Web, 공개 API 사용자 | `api-client-public` |
| Submission API | 34 | 소명·정정·문의·구독 intake | Public/Response SvelteKit server only | `api-client-submission` |
| Control API | 131 | 조사·검토·공개·운영 command/query | Review Console server only | `api-client-control` |
| Identity Provider BFF routes | 6 | 익명 login, callback, action-bound step-up, logout, security management redirect | Browser ↔ Review Console BFF | BFF route contract; generated browser client 없음 |
| Private Identity Service | 9 | OIDC transaction, session, step-up authorization를 Rust Identity API에서 처리 | Review Console BFF server only | `api-client-identity-internal` |

외부 operation contract 합계는 **212개**다. Private Identity Service 9개 operation은 외부 212개와 분리된 service-assertion API다.

## 권위 파일

- `operation-contracts.yaml`: 외부 212개 operation의 method/path/auth/schema/audit/idempotency
- `public-api.openapi.yaml|json`: 41 operations
- `submission-api.openapi.yaml|json`: 34 operations
- `control-api.openapi.yaml|json`: 131 operations
- `identity-provider.openapi.yaml|json`: Review Console BFF의 6개 browser-facing identity route
- `identity-service-internal.openapi.yaml|json`: private Identity API의 9개 service-assertion operation

실제 구현에서는 Rust DTO와 Actix handler가 Public·Submission·Control·Private Identity OpenAPI JSON을 생성한다. Review Console BFF identity route는 SvelteKit server route contract를 따른다. 네 generated TypeScript client는 Rust 생성 JSON만 입력으로 사용한다.

## 불변식

- Public·Submission·Control·Identity 경계를 합치지 않는다.
- Public response에 private/editorial DTO를 serialize하지 않는다.
- Submission API는 editorial/publication state를 직접 변경하지 않는다.
- Browser는 Private Identity Service나 Control API를 직접 호출하지 않는다.
- 모든 non-GET write는 `Idempotency-Key`를 요구한다.
- versioned mutation은 canonical optimistic-concurrency contract를 따른다.
- `assurance_level: STEP_UP` command는 capability, bounded recent reauth, reason, audit를 요구한다. UI destructive confirmation과 security assurance는 분리한다.
- 501, generic placeholder JSON, undocumented endpoint를 허용하지 않는다.

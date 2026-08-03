# ADR-008: Public·Control·Submission API의 물리적 분리

- Status: Superseded by extension, retained as accepted boundary rule
- Date: 2026-07-10
- Extended by: ADR-013

## Decision

Public, Control, Submission은 별도 Rust binary, DB role, OpenAPI, TypeScript client, container, ingress다.

- Public API는 curated `public` schema를 read-only로 조회한다.
- Control API는 OIDC/RBAC가 적용된 내부 편집 command만 처리한다.
- Submission API는 token/email-session scoped external intake만 처리하고 `intake` schema 밖의 publication/editorial state를 변경하지 못한다.
- 외부 Response Portal은 Submission API만 server-side로 사용한다.

## Security outcome

잘못된 route 또는 frontend import 하나로 private data, editorial command, 외부 untrusted input이 같은 trust zone에 섞이는 위험을 줄인다. DB grant negative test, generated contract/client leakage test, browser bundle scan, network policy와 end-to-end submission tests로 강제한다.

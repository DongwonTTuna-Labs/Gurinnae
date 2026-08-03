# Deployment Inputs — No Open Product Decisions

제품, 화면, API, 데이터 모델, 권한, 기술 stack과 디자인에 미결정 항목은 없다.

실제 배포자가 제공해야 하는 값만 남는다.

| 입력 | 예 | 없을 때 동작 |
|---|---|---|
| 공개·내부·소명 domain | `gurine.example` | production preflight 실패 |
| PostgreSQL service credentials | secret manager | 해당 service 기동 실패 |
| encryption/session/HMAC keys | base64 secret | production 기동 실패 |
| OIDC issuer/client | 조직 IdP | Review Console 기동 실패 |
| SMTP/email credential | email provider | 제출 가능, 발송 readiness 실패 |
| S3-compatible storage | bucket/credential | upload/source readiness 실패 |
| 공공데이터 API key | data.go.kr/Open DART | 해당 connector disabled |
| 선택적 AI key | provider key | AI 보조 disabled, 결정적 탐지는 계속 |
| observability endpoint | OTLP/Sentry | production readiness 실패 또는 승인된 local sink |

정확한 환경변수와 조건은 `specs/config/secret-and-key-catalog.yaml`이 권위다.
이 입력은 제품 정책을 다시 결정하는 open decision이 아니다.

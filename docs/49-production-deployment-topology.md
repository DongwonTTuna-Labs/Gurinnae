# 49. Production Deployment Topology

기본 운영 배치는 Docker Compose compatible이며 Kubernetes로 옮겨도 service boundary를 유지한다.

- reverse proxy / TLS
- public-web
- review-console (internal ingress)
- response-portal
- public-api
- control-api (internal ingress)
- billing-gateway (internal ingress, disabled by default)
- submission-api
- worker replicas
- singleton/fenced scheduler
- one-shot checksummed role provisioner
- one-shot migrator
- PostgreSQL 18.4
- S3-compatible object storage
- SMTP/email provider
- OIDC provider
- OTLP collector

Public API와 public web만 일반 공개된다.
Control API는 private network와 authenticated BFF를 통해서만 접근한다.
Billing Gateway는 `internal`/`data` 네트워크에만 연결되고 Public Web BFF의
request-bound service assertion만 받는다. R6e에는 live payment provider channel,
provider host, merchant credential이 없으며 `TEST_ONLY` fixture 외 결제 실행은 fail-closed다.
Economics import는 Workflow Worker의 일반 DB pool과 분리된 선택적
`ECONOMICS_DATABASE_URL`만 사용하며, 설정할 경우 전용 `gurine_economics_importer`
role이어야 한다. 미설정 상태에서는 economics execution만 fail-closed다.
PostgreSQL 시작 뒤 checksummed role provisioner가 exact superuser control-plane
identity로 R6e 역할을 생성하거나 pristine 상태를 검증하고, 성공한 뒤에만 migrator가
시작된다. 네 R6e 역할은 영구적으로 password가 없으며 membership도 갖지 않는다.
운영 LOGIN 역할의 인증은 runtime/migrator와 분리된 operator-owned client certificate,
peer 또는 IAM 경계가 담당한다.
Submission API는 공개 가능하지만 strict rate limit, origin, anti-abuse, token scope를 적용한다.

# 49. Production Deployment Topology

기본 운영 배치는 Docker Compose compatible이며 Kubernetes로 옮겨도 service boundary를 유지한다.

- reverse proxy / TLS
- public-web
- review-console (internal ingress)
- response-portal
- public-api
- control-api (internal ingress)
- submission-api
- worker replicas
- singleton/fenced scheduler
- one-shot migrator
- PostgreSQL 18.4
- S3-compatible object storage
- SMTP/email provider
- OIDC provider
- OTLP collector

Public API와 public web만 일반 공개된다.
Control API는 private network와 authenticated BFF를 통해서만 접근한다.
Submission API는 공개 가능하지만 strict rate limit, origin, anti-abuse, token scope를 적용한다.

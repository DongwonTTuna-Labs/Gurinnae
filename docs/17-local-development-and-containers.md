# 로컬 개발과 컨테이너

## 1. 목표

개발자는 빠른 host loop와 완전한 container 재현성을 모두 가져야 한다. PostgreSQL/SQLx 동작은 실제 PostgreSQL 18.4에서 검증하고, 개발/CI/운영 image 차이를 최소화한다.

## 2. 공식 개발 모드

### 2.1 DB-only Docker

권장 일상 개발:

```bash
make bootstrap
make dev-infra
make db-migrate
make dev-backend
make dev-frontend
```

- PostgreSQL만 Docker
- Rust/Bun은 host
- `cargo watch`, SvelteKit HMR
- host에서 exact toolchain 확인

### 2.2 Full-container

```bash
make dev-full
```

- postgres
- migrator
- public-api
- control-api
- worker
- scheduler
- public-web
- review-console

모든 service를 build/health/order까지 검증한다. CI smoke와 신규 개발환경 검증에 사용한다.

### 2.3 Dev toolchain image

`infra/docker/dev/Dockerfile`은 Rust, Bun, SQLx CLI, cargo-watch, cargo-nextest, PostgreSQL client를 담는다. host 설치가 어려운 경우 `docker compose run dev` 형태로 사용한다.

## 3. Version/Image pinning

- `postgres:18.4-bookworm`
- exact Rust/Bun base tags
- `latest`, `edge`, `canary` 금지
- release image digest는 `infra/images.lock`에 기록
- image update PR은 CVE, compatibility, build/smoke evidence 포함

Bookworm 계열을 baseline으로 사용한다. Alpine 전환은 native TLS, parser, debugging, libc compatibility를 검증하는 ADR 없이는 금지한다.

## 4. Compose dependency graph

```text
postgres --healthy--> migrator --completed-successfully--> APIs/workers
public-api --healthy--> public-web
control-api --healthy--> review-console
```

Scheduler/worker는 migrator 완료 후 시작한다. `depends_on`만 믿지 않고 각 service가 migration compatibility를 startup/readiness에서 확인한다.

## 5. PostgreSQL local policy

- named volume: local persistent mode
- test Compose: ephemeral isolated volume
- dev password는 명시적 non-secret placeholder
- production credential과 이름을 재사용하지 않음
- port는 기본 localhost bind
- initialization SQL은 roles/extensions bootstrap만; domain migrations는 SQLx

## 6. Dockerfile 표준

### Rust service

- build stage exact Rust
- `cargo-chef`는 baseline에서 사용하지 않는다. 측정된 clean-build 개선과 ADR이 있을 때만 추가
- `--locked`
- final image non-root
- CA/timezone 필요한 최소 runtime package
- binary와 build metadata만 copy
- health command 또는 HTTP probe
- SIGTERM graceful shutdown

### SvelteKit/Bun

- exact Bun builder/runtime
- `bun install --frozen-lockfile`
- production build
- dev dependency 제외 전략 검증
- `bun ./build/index.js`
- non-root
- writable temp만 허용
- SSR health and signal smoke

## 7. Bun adapter gate

`svelte-adapter-bun`은 community adapter이므로 다음을 version update와 release에서 검사한다.

- Linux amd64 startup
- target deployment architecture startup
- SSR route/status/body
- streaming response
- cookie set/read/delete
- forwarded host/proto only through trusted proxy
- request body limit
- static asset/cache headers
- graceful SIGTERM
- readiness during shutdown
- memory leak/basic load smoke

실패 시 version rollback이 우선이다. Node runtime으로 임의 전환하지 않고 ADR과 사용자 승인을 요구한다.

## 8. Networking

- internal service name 사용
- public API만 필요한 외부 ingress
- control API는 internal/restricted ingress
- postgres/object storage는 external publish 금지
- egress는 source/model allowlist
- public-web에서 control-api DNS/credential 불필요

## 9. Secrets

`.env.example`에는 변수 이름과 안전한 placeholder만 있다.

- real `.env` Git 금지
- Build ARG로 secret 전달 금지
- image layer/cache/log에 secret 금지
- Docker secret 또는 runtime secret manager
- browser-visible env prefix 별도 audit

## 10. Health

- `/healthz`: process liveness; dependency 전체 검사 금지
- `/readyz`: required DB/migration/pool/read model readiness
- worker: process + lease loop status metric
- web: SSR API dependency를 적절히 반영

External source 장애가 public API liveness를 떨어뜨리지 않는다. Source freshness는 별도 상태다.

## 11. Standard commands

```text
make dev-infra
make dev-full
make dev-down
make dev-clean
make db-migrate
make db-reset
make docker-build
make docker-smoke
make docker-logs
```

`dev-clean`은 destructive confirmation 또는 명시적 CI flag를 요구한다.

## 12. Container acceptance

- exact image tags only
- root user 없음
- health dependency order
- migration failure면 app 시작 실패
- control API external port 기본 미노출
- secret pattern 없음
- immutable fixture mount read-only
- database data survives normal restart
- test data does not leak between runs
- SIGTERM graceful
- clean rebuild reproducible


## Development shell image

`compose.yaml` defines a `dev-shell` service built from
`infra/docker/dev/Dockerfile`. It bind-mounts the monorepo, persists only package/build
caches, waits for PostgreSQL health, and exposes no public port. The image contains the
exact Rust and Bun toolchains, PostgreSQL client, SQLx CLI, cargo-watch, and cargo-nextest.
Helper-tool versions must be resolved, pinned and recorded before the final image is accepted
build; an omitted version is a hard failure rather than an implicit latest install.


## 고정된 개발 이미지 도구

- SQLx CLI `0.9.0`
- cargo-watch `8.5.3`
- cargo-nextest `0.9.140`

Compose 명령은 `--env-file infra/versions.env`를 반드시 사용한다. 따라서 Dockerfile의 build arg와 문서 기준선이 어긋나면 이미지 빌드가 즉시 실패한다.

## 18. PostgreSQL 18 volume contract

PostgreSQL 18 changed the official image layout. Gurine sets `PGDATA=/var/lib/postgresql/18/docker`, mounts named storage at `/var/lib/postgresql`, and uses the same root for test tmpfs. `/var/lib/postgresql/data` is a forbidden legacy target in every PostgreSQL 18 Compose or deployment manifest.

A local upgrade never silently reuses or deletes an old volume. The operator must identify the previous major version and mount layout, perform an export/restore or approved in-place procedure, and preserve evidence. The Docker smoke suite writes data, recreates only the container, and proves persistence.

## 19. Tool-image reproducibility exception

The SQLx CLI 0.9.0 line omits `--locked` only because the upstream package lacks the required lockfile. The exact CLI version and feature set remain fixed. Final supply-chain verification must attach install logs, resolved dependency graph, SBOM, vulnerability scan, clean-build comparison, and immutable image digest. This exception cannot be copied to other Cargo-installed tools.

## 20. Bun-only compatibility

The SvelteKit images build and run with Bun. Package metadata that mentions Node does not authorize a Node fallback. Both apps must pass clean Bun install, `svelte-check`, production build, Bun SSR startup, header/cookie/stream tests, and graceful shutdown. Any compatibility override requires a dedicated ADR and renewed supply-chain review.

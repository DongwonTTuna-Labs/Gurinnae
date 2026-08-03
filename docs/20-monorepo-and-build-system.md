# 모노레포와 빌드 시스템

## 1. 목표

Rust, TypeScript, OpenAPI, DB migration, container가 한 commit에서 원자적으로 검증되도록 한다. 그러나 빌드 orchestration 자체가 별도 대형 플랫폼이 되지 않게 한다.

## 2. Workspaces

### Cargo

Root `Cargo.toml`은 모든 `services/*`, `crates/*`, `xtask`를 명시한다. Glob으로 예상치 못한 crate를 포함하지 않는다.

### Bun

Root `package.json` workspaces:

```json
{
  "workspaces": ["apps/*", "packages/*"]
}
```

Exact `packageManager`와 `engines`/preinstall version check를 둔다.

## 3. Orchestration

- Make: 개발자/CI의 stable entrypoint
- `cargo xtask`: Rust-aware cross-project tasks(OpenAPI, DB, fixtures, verify)
- Bun root scripts: three-app frontend/codegen and UI-contract tasks

Nx/Turbo는 baseline에서 사용하지 않는다. 캐시/규모 문제가 측정되면 ADR로 도입한다.

## 4. Root commands

```text
bootstrap
spec-check
format / format-check
lint
typecheck
test / test-integration
acceptance
db-up / db-migrate / db-reset
sqlx-prepare / sqlx-check
openapi-generate / openapi-check
client-generate / client-check
dev-infra / dev-backend / dev-frontend / dev-full
docker-build / docker-smoke
verify
```

`verify`는 빠른 검사만 이름을 바꾼 것이 아니라 release-relevant 전체 gate여야 한다. 빠른 loop는 `check-fast` 같은 별도 target을 둔다.

## 5. Dependency ownership

- Rust dependency는 workspace dependencies에서 기본 버전/feature를 중앙화
- 각 crate는 필요한 feature만 enable
- TypeScript dependency는 root override/catalog 또는 package별 exact version + lock
- duplicate major를 정기 점검
- generated tool version은 baseline과 config에 명시

## 6. Build outputs

```text
target/
node_modules/
apps/*/.svelte-kit/
apps/*/build/
reports/
artifacts/
```

은 Git 제외. 다음은 commit:

```text
Cargo.lock
bun.lock
.sqlx/
specs/generated/*.openapi.json
packages/api-client-*/src/generated/**
```

## 7. Generated artifact ownership

Generated path에는 README/header로 direct edit 금지를 표시한다. CI가 generator input/tool version hash를 검사하고 clean regen diff를 실패시킨다.

## 8. Change impact

- domain change: Rust unit/application/acceptance
- DB query/migration: PG integration + SQLx prepare
- API DTO/route: OpenAPI + clients + frontend compile
- frontend route: Svelte/Playwright
- image/tool version: full build/smoke
- publication policy: domain/DB/API/UI/acceptance/eval

PR template 또는 automated classifier가 required jobs를 줄 수 있으나 safety jobs는 path filtering으로 skip하지 않는다.

## 9. Reproducibility

- exact toolchain/package/image
- frozen locks
- no network during generated/check phase where possible
- deterministic OpenAPI/client
- source date/build metadata policy
- artifact checksums/SBOM

## 10. Blueprint policy

`specs/repository/final-tree.yaml`은 완성 source tree의 물리적 계약이다. 구현된 실제 root files가 이 계약과 일치해야 하며 누락·추가 runtime boundary는 validator와 ADR 검사를 통과해야 한다.

## 11. v3 Product/UX commands

명세 패키지와 materialized repository는 다음 stable entrypoint를 제공한다.

```text
ui-generate     screen catalog에서 94개 screen Markdown과 route index 재생성
ui-check        screen/data/role/navigation/component/event/prototype 계약 검증
show-product-contract  최종 제품·화면·API 범위 출력
```

`spec-check`는 `ui-check`를 포함한다. Screen YAML을 변경하고 generated Markdown을 갱신하지 않거나, READY operation이 OpenAPI에 없거나, route/app/auth boundary가 어긋나면 실패한다.

Cargo workspace는 20개 member, Bun workspace는 3 apps + 4 packages를 baseline으로 한다. Apps/services/packages를 줄이거나 합치는 것은 단순 refactor가 아니라 ADR과 product/security review가 필요한 boundary 변경이다.

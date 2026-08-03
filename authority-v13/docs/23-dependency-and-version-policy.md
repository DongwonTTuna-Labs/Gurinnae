# Dependency·Version·Supply-chain 최종 정책

상태: **FINAL**  
권위: `technology-baseline.yaml`, `cargo-bom.toml`, `bun-bom.json`, lockfile과 image digest

## 1. 원칙

- Direct dependency와 tool version은 exact pin이다.
- Transitive graph는 `Cargo.lock`과 `bun.lock`이 고정한다.
- Floating Docker tag와 `latest`, `edge`, `canary`는 금지한다.
- Core dependency 변경은 ADR, compatibility, regeneration, container evidence가 필요하다.
- 사용하지 않는 dependency와 feature는 제거한다.

## 2. 기준 조합

```text
Rust 1.97.0
Actix Web 4.14.0
Tokio 1.47.1
SQLx/SQLx CLI 0.9.0
Utoipa 5.5.0
PostgreSQL 18.4
Bun 1.3.14
Svelte 5.56.4
SvelteKit 2.69.2
svelte-adapter-bun 1.0.1
TypeScript 5.9.3
Biome 2.5.3
svelte-check 4.3.1
Vite 7.1.4
Playwright 1.55.0
@hey-api/openapi-ts 0.99.0
@hey-api/client-fetch 0.13.1
Valibot 1.1.0
```

TypeScript 5.9.3은 adapter의 TypeScript `^5` peer 범위와 generated client strict compile을 동시에 충족하도록 선택했다. 과거 6.x 문구는 폐기한다.

## 3. SQLx

SQLx 0.9는 runtime/TLS feature를 분리한다.

```text
runtime-tokio
tls-rustls-ring-webpki
```

과거 combined feature `runtime-tokio-rustls`는 금지한다. SQLx CLI 0.9.0은 upstream install lock 부재 때문에 정확한 version/features로 설치하고, resolved graph·SBOM·scan·clean-build·image digest로 보상한다. 다른 도구에 이 예외를 확장하지 않는다.

## 4. Bun/SvelteKit

- Bun이 install, script, build, SSR runtime을 담당한다.
- Node production fallback은 ADR 없이는 금지한다.
- Clean install, SvelteKit build, Bun SSR start, cookie/header/stream/shutdown smoke를 통과한다.
- Generated client는 별도 strict tsconfig에서 compile하며 직접 수정하지 않는다.
- Handwritten TypeScript는 `exactOptionalPropertyTypes`를 포함한 전체 strict 정책을 적용한다.

## 5. Supply chain

필수 evidence:

- lockfile checksum
- dependency graph
- license policy
- advisory scan
- `cargo deny` / `cargo audit`
- first-party/overall `cargo geiger` report
- SBOM
- image vulnerability scan
- base image digest
- build provenance
- two clean-build comparison

First-party Rust unsafe는 0이어야 한다. Transitive dependency의 unsafe는 숨기지 않고 report·review한다.

## 6. Update

Automation은 PR만 만들며 merge하지 않는다. Core update는 format/compile/test, SQLx, five OpenAPI, four API clients, three SSR apps, container, acceptance, recovery를 전부 재검증한다.

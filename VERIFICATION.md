# VERIFICATION — Gurine Source Tree v13.0.0

검증 기준 시각: **2026-07-13 UTC**

## 권위와 범위

이 source tree는 다음 첨부 파일만 권위 사양으로 사용해 구현했다.

```text
gurine-codex-authority-pack-v13.0.0-20260712.zip
SHA-256 960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5
```

이 문서는 authority pack 자체가 아니라 완성된 Rust·SvelteKit source tree의 실제 검증 기록이다. MVP, scaffold, fixture-only 대체물, 일부 화면/API, placeholder, 501 응답 또는 skip된 hard gate는 합격 결과에 포함하지 않는다.

## Hash-pinned 검증 환경

| 역할 | 고정된 환경 |
|---|---|
| Authority validator | Python 3.13.5 slim Bookworm `sha256:4c2cf991…30987419`, `requirements-spec.txt --require-hashes` |
| Rust | Rust 1.97.0 Bookworm `sha256:7d0723df…6fe3b6a`와 `Cargo.lock --locked` |
| Bun / SvelteKit | Bun 1.3.14 Debian `sha256:9dba1a1b…fc9db6f`와 `bun.lock --frozen-lockfile` |
| PostgreSQL | PostgreSQL 18.4 Bookworm `sha256:d9c83446…5d79818` |
| Malware / telemetry | ClamAV 1.4.3, OpenTelemetry Collector 0.131.1 digest pin |
| Parser | Poppler 25.06.0와 Tesseract 5.5.0 source SHA-256 pin, ENG/KOR trained-data digest 확인 |

전체 image digest는 `infra/images.lock`, 언어·도구 버전은 lockfile과 Dockerfile에 기록되어 있다.

## 최종 source-tree 검증

실행:

```bash
make verify-final
```

종료 결과:

```text
all authority, source, runtime, container, recovery and UI hard gates: PASS
```

### Authority와 무결성

| Gate | 실제 결과 |
|---|---:|
| Strict authority validator | warnings 0 / errors 0 / PASS |
| 화면 / component | 94 / 58 |
| Public / Submission / Control / Browser Identity operation | 41 / 34 / 131 / 6 |
| 외부 operation / private Identity operation | 212 / 9 |
| Query / command / HTTP non-GET write | 107 / 105 / 102 |
| Acceptance feature / scenario / executable mapping | 35 / 271 / 271 |
| Agent / tool / eval | 5 / 9 / 50 |
| Connector / upstream operation | 6 / 44 |
| Detection rule / evaluation | 10 / 300 |
| Parser format / golden fixture | 8 / 15 |

Authority validator는 필수 파일, traceability, 금지된 placeholder·불완전 surface, schema, cryptographic vector, parser/detection/agent reference를 strict mode로 검사했다. MANIFEST의 모든 파일 digest도 검증했다.

### PostgreSQL 18.4와 SQLx

| Gate | 실제 결과 |
|---|---:|
| Migration | 24 / 24 PASS |
| Active table / first-party function | 107 / 72 |
| Trigger / RLS policy / runtime role | 37 / 5 / 13 |
| Optimistic concurrency | 64 / 64 resolved |
| Named runtime canary | 69 / 69 PASS |
| Expanded runtime assertion | 133 PASS |
| SQLx | 0.9.0 `prepare --workspace --check` PASS |

실제 migrated PostgreSQL에서 audit chain, SECURITY DEFINER search path, role/RLS, optimistic concurrency, assertion replay, submission session promotion/revoke, cross-session IDOR, attachment, correction, subscription과 terminal mutation을 실행 검증했다.

### Rust workspace

32개 Cargo member 전체에 대해 다음이 통과했다.

```text
cargo fmt --all -- --check                                      PASS
cargo clippy --locked --workspace --all-targets -- -D warnings PASS
cargo test --locked --workspace --all-targets --no-run         PASS
cargo test --locked --workspace --all-targets                  PASS
```

first-party unsafe/panic/unwrap/expect 금지, crate root 속성, 파일·함수 제한과 계층 의존성은 authority validator의 code-quality gate에서도 통과했다.

### Bun, SvelteKit와 generated client

| Gate | 실제 결과 |
|---|---:|
| Bun workspace | 9 |
| Biome | PASS |
| Svelte check | 0 errors / 0 warnings |
| Workspace unit tests | PASS |
| SvelteKit production SSR build | public-web / response-portal / review-console PASS |
| OpenAPI client | Public / Submission / Control / Private Identity PASS |
| Deterministic regeneration | 4 / 4, source digest unchanged |

Svelte 템플릿 symbol 사용은 Svelte compiler를 이해하는 `svelte-check`가 검증한다. Biome는 TypeScript·JavaScript·CSS formatting/lint를 담당하며 generated client와 1 MiB 초과 Control OpenAPI는 전용 strict typecheck·OpenAPI parser·deterministic codegen gate가 검증한다.

### API와 worker runtime

다음 실제 PostgreSQL/object-store/ClamAV/SMTP/OIDC/egress 경로가 모두 통과했다.

- Control API 131-operation assertion/idempotency/audit/outbox
- Submission API 34-operation session/encryption/object-bytes/ClamAV
- Identity OIDC/session/CSRF/step-up/assertion
- Public API 41-operation projection/OpenAPI
- 6 connector / 44 operation ingest와 checkpoint/raw/outbox/object-store
- 10-rule / 5-agent analysis와 provider budget/tool/citation
- analysis deny/retry/redacted-DLQ/lease recovery negative runtime
- credential-injecting AI egress gateway production path
- workflow 8-event와 notification 11-type fenced consumers
- ingest/workflow/projection/notification terminal retry·DLQ·redaction
- document extraction부터 ingest/analysis/projection/notification까지의 end-to-end outbox/job fencing
- source cron/rule activation/restriction expiry scheduler
- caller/host/method/DNS pin/redirect/object-store egress boundary

### Production container와 복구

| Gate | 실제 결과 |
|---|---:|
| First-party production image | 17 / 17 PASS |
| Production Compose service | 20 / 20 PASS |
| Runtime restrictions | non-root / read-only / network isolation / volume / SIGTERM PASS |
| 강제 종료 후 API restart/health recovery | PASS |
| Backup/restore | encrypted PostgreSQL + object store clean restore PASS |
| Recovery receipt | RPO/RTO 포함 PASS |

### Browser와 visual

| Gate | 실제 결과 |
|---|---:|
| Route + Browser Identity E2E | 95 / 95 PASS |
| Route visual snapshots | 282 / 282 PASS |
| Viewports | compact / medium / wide |
| SSR / accessibility / responsive assertions | 94개 화면 PASS |

## Archive 검증 규칙

release source artifact는 `source/` 단일 root의 `gurine-source-v13.0.0.tar.gz`, SHA-256
sidecar와 extraction receipt다. 생성 후 검증 프로세스가 다음을 다시 확인한다.

```bash
make source-archive
make clean-extraction-verify
```

`clean-extraction-verify`는 sidecar SHA-256, 중복·traversal·link·special-file 금지, 단일
`source/` root, 내부 MANIFEST의 정확한 member set과 source-tree digest를 확인한 뒤 새 임시
디렉터리의 추출본에서 `make verify-prearchive`를 실행한다. authoritative acceptance와
`make verify-final`은 이 target이 실행하지 않는다. release workflow는 이후 원 체크아웃에서
명시적인 `ACCEPTANCE_*` 7개 입력으로 `make verify-acceptance`를 실행해 archive와 receipt
digest를 acceptance evidence에 바인딩한다.

## Source-tree 판정

```text
SPECIFICATION_AUTHORITY: PASS
POSTGRESQL_RUNTIME_AND_SQLX: PASS
RUST_WORKSPACE: PASS
SVELTEKIT_AND_CODEGEN: PASS
API_AND_WORKER_RUNTIME: PASS
PRODUCTION_STACK_AND_RECOVERY: PASS
BROWSER_AND_VISUAL: PASS
SOURCE_TREE_HARD_GATES: PASS
```

Archive sealing과 clean-extraction hard gate가 실제로 통과하기 전에는 `ARTIFACT_READY`를 선언하지 않는다.

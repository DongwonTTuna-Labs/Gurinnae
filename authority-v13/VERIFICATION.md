# VERIFICATION — 구린네 Codex Final Authority Pack v13.0.0

검증일: **2026-07-12**

## 정확한 산출물 성격

이 패키지는 구린네 애플리케이션 구현 source가 아니다. Codex가 제품·화면·API·DB·인증·Agent·Connector·운영 정책을 새로 발명하지 않고 전체 Rust·SvelteKit 애플리케이션을 구현하기 위한 **최종 권위 사양**이다.

따라서 이 기록이 증명하는 것은 authority pack의 문법·의미·reference baseline·PostgreSQL migration·archive 무결성이다. 실제 Cargo build, SQLx query, SvelteKit 94 route, Docker 운영 stack은 Codex가 구현한 source tree에서 다시 증명해야 한다.

## 최종 권위 범위

| 영역 | 결과 |
|---|---:|
| 화면 / Component | 94 / 58 |
| Public / Submission / Control / Browser Identity operation | 41 / 34 / 131 / 6 |
| 외부 operation 합계 | 212 |
| Private Identity operation | 9 |
| Query / Command / HTTP non-GET write | 107 / 105 / 102 |
| Command semantics / Persistence mapping | 105 / 212 |
| Event / Integration event | 99 / 26 |
| Optimistic concurrency | 64 |
| PostgreSQL migration / active table / function | 24 / 107 / 72 |
| Trigger / RLS policy / runtime role | 37 / 5 / 13 |
| Cargo member / Bun workspace / Compose service | 32 / 9 / 20 |
| Agent / Tool / Eval | 5 / 9 / 50 |
| Connector / Upstream operation | 6 / 44 |
| Parser format / golden fixture | 8 / 15 |
| Detection rule / Eval | 10 / 300 |
| Acceptance feature / scenario | 35 / 271 |

## v13 Submission security closure

다음 raw bearer-token 기반 흐름을 제거했다.

```text
/v1/response-requests/{requestToken}/...
/v1/correction-request-drafts/{draftToken}/...
/v1/subscriptions/{managementToken}/...
```

최종 경계:

```text
Browser magic URL
→ same-origin SvelteKit BFF
→ request-bound BFF Service Assertion
→ one-time token exchange
→ encrypted host-only scoped submission session cookie
→ token-free canonical URL
→ BFF server-only generated client
→ Submission API scoped session validation
```

지원 session kind:

- response pending verification
- response active
- response receipt
- correction draft
- correction receipt
- subscription verification
- subscription management

PostgreSQL procedure와 RLS는 cross-session IDOR, token replay, session reuse, duplicate final submission과 terminal-session mutation을 차단한다.

## Authority validator

실행:

```bash
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validate_final_spec.py --strict
```

결과:

```text
warnings: 0
errors: 0
RESULT: PASS
```

주요 결과:

```text
operations                       212
submission_operations            34
command_semantics               105
persistence_mappings            212
optimistic_concurrency           64
acceptance_executable_mappings  271
cryptographic_envelope_vectors    5
parser_golden_outputs             15
rule_evaluation_cases            300
agent_eval_cases                  50
```

증거:

- `verification/static-validation.txt`
- `verification/static-validation.json`

## 두 개의 독립 Python 환경

두 개의 별도 CPython 3.13.5 virtualenv에서 hash-pinned dependency 설치와 evidence 제외 validator를 실행했다.

```text
Dependency freeze        IDENTICAL
Validator output         IDENTICAL
Result                   PASS / PASS
```

증거:

- `verification/python-clean-environments.yaml`
- `verification/fresh-venv/`

## PostgreSQL 18.4 실제 런타임

실제 PostgreSQL 18.4에서 24개 migration을 적용했다.

```text
Migration                       24 / 24 PASS
Active table                    107
Active first-party function      72
Trigger                          37
RLS policy                        5
Concurrency catalog              64 / 64 resolved
Named runtime canary             69 PASS
Expanded runtime assertion      133 PASS
```

주요 canary:

- Extension schema 격리와 SECURITY DEFINER search path
- DB-owned audit chain과 mutation 차단
- Service·Actor·Submission assertion replay 차단
- Response magic token exchange·OTP promotion·session revoke
- Response/Correction attachment cross-session IDOR 차단
- Correction draft preview·atomic submit·receipt
- Subscription verify/manage/unsubscribe lifecycle
- Submission API direct table write 차단
- Schema mapping·queue·source optimistic concurrency
- Runtime role superuser·BYPASSRLS 0건

안정 baseline: `verification/postgres-runtime-baseline.json`

## OpenAPI와 generated clients

검증 조합:

```text
Bun                     1.3.14
TypeScript              5.9.3
@hey-api/openapi-ts     0.99.0
@hey-api/client-fetch   0.13.1
```

결과:

```text
Public client                 PASS / 41 operations
Submission client             PASS / 34 operations
Control client                PASS / 131 operations
Private Identity client       PASS / 9 operations
Second generation diff        0 bytes
Strict TypeScript compile     PASS
```

증거: `verification/codegen-compatibility.json`

## Parser·Detection·Agent

```text
Parser/OCR exact golden     15 / 15 PASS
Detection reference        300 / 300 PASS
Agent policy/replay         50 / 50 PASS
Visual reference render     10 / 10, page error 0
```

## 아직 구현 source에서 증명해야 하는 것

- Cargo workspace compile, fmt, clippy, nextest
- first-party `unsafe`·panic·file/function size gate
- 실제 SQLx query macro와 `.sqlx/`
- Rust-generated OpenAPI와 committed client regeneration
- SvelteKit 94개 route, E2E, visual, accessibility
- Docker development/test/production full stack
- 공식 live source activation preflight
- 실제 OIDC·SMTP·object store·ClamAV·OTLP integration
- backup/restore, graceful shutdown, load/performance
- 실제 기관·업체 기록의 법률·편집 검토

## 판정

```text
SPECIFICATION_AUTHORITY: PASS
SUBMISSION_SECURITY_BOUNDARY: PASS
POSTGRESQL_RUNTIME_BASELINE: PASS
OPENAPI_CODEGEN: PASS
PARSER_DETECTION_AGENT_BASELINE: PASS
ARCHIVE_SEALING: PASS after release archive verification
```

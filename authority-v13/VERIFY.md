# VERIFY — 구린네 Codex Final Authority Pack v13.0.0

이 문서는 authority pack 자체의 무결성·정합성·reference baseline을 검증한다. 실제 Rust·SvelteKit 애플리케이션의 build와 운영 검증은 Codex가 구현한 source tree에서 `FINAL_BUILD_CONTRACT.md`에 따라 별도로 수행한다.

## 지원 환경

- CPython `3.13.5`
- Node.js `>=22`와 npm
- PostgreSQL `18.4` runtime verifier는 bundled embedded PostgreSQL package 사용
- Bun `1.3.14`는 OpenAPI client 재생성 증거에서 사용

## 1. Hash-pinned Python authority environment

```bash
python3 --version
# Python 3.13.5

python3 -m venv /tmp/gurine-authority-venv
. /tmp/gurine-authority-venv/bin/activate
python -m pip install --require-hashes -r requirements-spec.txt
```

## 2. 정적·의미·reference 검증

```bash
PYTHONDONTWRITEBYTECODE=1 python -B scripts/validate_final_spec.py --strict
```

기대 결과:

```text
warnings: 0
errors: 0
RESULT: PASS
```

검증 범위:

- YAML·JSON duplicate key 거부
- 94개 화면과 action·assurance·API·implementation traceability
- 외부 operation 212개와 Private Identity operation 9개
- 105개 command semantics, 212개 persistence mapping, 64개 optimistic concurrency contract
- Submission BFF service assertion·one-time token exchange·scoped session boundary
- Response·Correction·Subscription session IDOR·replay·terminal revocation 계약
- OpenAPI 3.1 문서와 네 generated client 증거
- PostgreSQL schema·role·RLS·function·trigger·runtime baseline
- Parser/OCR 15개 golden fixture
- Detection 300개와 Agent 50개 reference harness
- First-party Rust unsafe/panic 금지와 Rustful·Svelteful 품질 계약
- 271개 acceptance scenario와 executable mapping
- secret pattern·symlink·금지 경로 검사

## 3. PostgreSQL 18.4 runtime 검증

Manifest를 생성한 최종 authority tree에서 실행한다.

```bash
make verify-postgres-runtime
```

이 명령은:

1. authority tree digest를 계산한다.
2. 임시 경로에 runtime 결과를 기록한다.
3. 24개 migration을 PostgreSQL 18.4에 clean apply한다.
4. catalog·privilege·RLS·audit·lifecycle·concurrency·Submission session canary를 실행한다.
5. 결과의 안정 필드를 `verification/postgres-runtime-baseline.json`과 비교한다.
6. 검증 전후 authority tree가 byte-identical인지 확인한다.
7. `MANIFEST.sha256`을 검증한다.

기대 baseline:

```text
Migration                       24 / 24
Active table                    107
Active first-party function      72
Trigger                          37
RLS policy                        5
Optimistic concurrency           64 / 64
Named runtime canary             69 PASS
Expanded runtime assertion      133 PASS
```

## 4. Parser/OCR golden 검증

```bash
PYTHONDONTWRITEBYTECODE=1 python -B specs/parsers/reference_harness.py \
  --json-output /tmp/gurine-parser-reference.json
```

기대 결과:

```text
15 / 15 PASS
```

지원·검증 범위는 CSV, XML, XLSX, DOCX, HWPX, digital PDF, scanned PDF OCR과 binary HWP quarantine을 포함한다.

## 5. 내부 Manifest 검증

배포받은 archive에서는 Manifest를 다시 만들지 않고 다음만 실행한다.

```bash
sha256sum --check MANIFEST.sha256
```

## 6. Archive 검증

Archive와 sidecar를 같은 디렉터리에 둔다.

```bash
sha256sum --check gurine-codex-authority-pack-v13.0.0-20260712.zip.sha256
sha256sum --check gurine-codex-authority-pack-v13.0.0-20260712.tar.gz.sha256

python -B gurine/scripts/verify_release_archives.py \
  gurine-codex-authority-pack-v13.0.0-20260712.zip \
  gurine-codex-authority-pack-v13.0.0-20260712.tar.gz
```

Archive verifier는 checksum, ZIP CRC/TAR readability, 단일 `gurine/` root, traversal, link/device, 내부 Manifest, clean-extraction strict validator, ZIP/TAR member/content 동일성을 검사한다.

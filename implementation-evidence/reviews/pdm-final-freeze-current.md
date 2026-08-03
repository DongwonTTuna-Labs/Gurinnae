# PdM implementation-gate review — 2026-07-19 (fresh current-worktree audit)

이 리뷰는 authority-v13 ZIP SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`와 현재
worktree만 기준으로 수행했다. 이전 리뷰 문서는 재판정 근거로 사용하지
않았다. 리뷰 대상 commit은 `5a3431b`이며, worktree는 dirty 상태다.

## Verdict

```text
VERDICT: CHANGES_REQUIRED
ROLE: PDM
REVIEWED_COMMIT: 5a3431b
WORKTREE_DIGEST: c746dc3e6999f4a60fa058402d5f41efdaa3372c403c3ef1d9956e7970846cc2
```

## P0 BLOCKERS

### PDM-FRESH-001 — 여정 receipt가 하나의 source snapshot에 묶이지 않음

`implementation-evidence/runtime-journey-receipts/flow-01..07-20260719.json`은
source digest `27300c584021ee4b5b4d27562490d50c2e5d630259f2e5c01c409b779a88e5cf`
및 correlation ID `9148df41-554e-4645-b0fe-9f82822a1c35`를 기록한다.
`flow-08..10-20260719.json`과 `pdm-003-observability-20260719.json`은
각각 digest `65621dbb71edf24ebd2edcde8e4b301a9fec2cdb0dd18d506b76a9a09bb53674`
및 correlation ID `b772c0c6-1c24-4c85-b090-60fa85f60b7d`를 기록한다.
현재 generator와 동일한 source-tree digest는
`c746dc3e6999f4a60fa058402d5f41efdaa3372c403c3ef1d9956e7970846cc2`다.
따라서 각 receipt의 `pass: true`는 보이지만 열 개 여정과 관측 창이 현재
source/archive를 증명하지 않는다. 이는 durable outcome의 재현성과
운영 소유권을 깨는 P0다.

### PDM-FRESH-002 — MANIFEST가 현재 source와 불일치

실행한 `sha256sum --check MANIFEST.sha256`는 `27 computed checksums did NOT
match`로 종료했다. 실패 집합에는 `db/migrations/0030_v13_submission_session_hardening.sql`,
`db/test-fixtures/control-runtime-seed.sql`, `services/control-api`의
addendum/query/response 파일, generated OpenAPI/client, `tests/integration/control-flow.py`,
그리고 flow-01..07 receipt가 포함된다. manifest/archive를 final source
snapshot으로 취급할 수 없으므로 최종 artifact gate는 닫히지 않았다.

### PDM-FRESH-003 — 439 acceptance execution evidence가 없음

최종 계약의 `run-acceptance-439`/`verify-execution-evidence`는 외부
`ACCEPTANCE_EVIDENCE_ROOT`, commit, source digest와 extraction receipt를
요구한다. 현재 환경에서 `ACCEPTANCE_EVIDENCE_ROOT`는 설정되지 않았고,
현재 tree에는 실행 receipt bundle이 없다. 따라서 271 시나리오의 실제
full-stack 실행 및 source/archive 바인딩을 확인할 수 없다. 선언·schema·정적
검사만으로는 PdM 운영 가능성 hard gate를 통과시킬 수 없다.

## P1 BLOCKERS

### PDM-FRESH-004 — omnichannel/provider poll의 운영 증거가 journey receipt에 없음

코드에는 scheduler의 `communication.delivery_poll_requested.v1`와
notification/egress poll 경로가 있으나, 현재 runtime journey evidence에는
provider callback/poll producer, provider receipt/reconciliation, consent/opt-out
상태를 실제 PostgreSQL·worker·gateway·UI를 관통한 receipt로 남긴 검증이
없다. `implementation-evidence/provider-runtime-closure.md`도 provider
adapter receipt generation 등을 별도 미완료 cross-surface gate로 명시한다.
메일/SMS/Telegram/WhatsApp/LINE/KakaoTalk 승인·통지라는 핵심 운영 경로를
완결됐다고 판단할 수 없다.

## RETEST OF PRIOR FINDINGS

- source/evidence digest parity: **OPEN** — 현재 digest와 2개 receipt 세대가
  서로 다르고 MANIFEST도 27개 mismatch다.
- flow receipt semantics: **PARTIALLY CLOSED** — 각 receipt의 정상/negative
  branch는 `pass: true`이며 일부 PostgreSQL audit/outbox/readback 증거가
  있으나 snapshot parity가 없어 final proof로 승격할 수 없다.
- typed operation samples: **CLOSED FOR THIS REVIEW** —
  `python3 scripts/verify_generated_responses.py`는 265개를 검사하고
  `errors: []`, `result: PASS`를 반환했다.
- Rust build/format: **CLOSED FOR THIS REVIEW** —
  `cargo check --workspace --locked`와 `cargo fmt --all -- --check`는
  통과했다. 이는 acceptance/evidence gate를 대체하지 않는다.

## EVIDENCE CHECKED

- `implementation-evidence/runtime-journey-receipts/flow-01..10-20260719.json`
  및 `pdm-003-observability-20260719.json`: pass flags, digest/correlation,
  PostgreSQL 18.4 migration/isolation, normal/negative receipts.
- `scripts/generate_pdm_flow_evidence.py`: 현재 source digest 산출 규칙.
- `sha256sum --check MANIFEST.sha256`: 27 checksum failures.
- `cargo check --workspace --locked`: PASS.
- `cargo fmt --all -- --check`: PASS.
- `git diff --check`: PASS.
- `python3 scripts/verify_generated_responses.py`: 265 checked, PASS.
- `Makefile`, `FINAL_BUILD_CONTRACT.md`, `implementation-evidence/provider-runtime-closure.md`:
  acceptance/external-evidence 및 provider 운영 gate 계약.

## REQUIRED NEXT EVIDENCE

1. source/runtime/evidence 입력을 freeze하고 Flow 01–10과 PDM-003을 한 번에
   재생성해 모두 동일한 current source digest와 correlation binding을 갖게
   한다.
2. `MANIFEST.md`/`MANIFEST.sha256`를 마지막으로 재생성하고 checksum 및
   source archive clean-extraction/member parity를 통과시킨다.
3. clean final commit에서 외부 evidence root로 439 acceptance 실행과
   extraction receipt를 생성하고 `make verify-execution-evidence` 및
   `make verify-acceptance`를 통과시킨다.
4. provider callback/poll, consent/opt-out, provider receipt/reconciliation을
   포함한 omnichannel end-to-end runtime receipt를 추가한다.

PDM_VERDICT: CHANGES_REQUIRED

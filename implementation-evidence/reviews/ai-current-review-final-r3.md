# AI/runtime fresh re-review — latest tree (2026-07-20)

권위 ZIP 단일 입력: `gurine-codex-authority-pack-v13.0.0-20260712.zip`
(`sha256:960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`).
리뷰어는 구현 파일을 수정하지 않았다.

## Verdict

```text
AI_VERDICT: CHANGES_REQUIRED
```

## Verified changes

- 다섯 valid fixture에 `schemaVersion`/V2 필드가 추가됐다.
- `make verify-authority`는 authority snapshot hash PASS까지 도달했다.
- safety receipt 전달과 redirect allow/deny header/5-hop URL chain 연결은 소스에
  존재한다.

## Blocking findings

### R3-001 — deterministic V2 fixture 계약이 repository harness와 불일치 (P0)

실행한 `python3 -B specs/agents/reference_harness.py` 결과는
`total: 50`, `result: FAIL`이며 다섯 valid provider fixture에서 모두
`additionalProperties ... schemaVersion/outcome/... unexpected`와 legacy
`status`/`abstention_reasons` required 오류가 발생했다. 즉 fixture는 V2로
바뀌었지만 권위 reference harness/expected-output은 아직 legacy 계약이고,
`actual output differs from expected`도 다섯 건 발생한다. 현재 deterministic
provider positive turn이 acceptance 기준으로 재현되지 않는다. harness와 V2
fixture/expected-output/validator를 하나의 권위 schema로 정렬하고 실제
provider turn + output validation + source lineage receipt를 재실행해야 한다.

### R3-002 — source access capability가 실제 asset rights decision으로 바인딩되지 않음 (P0)

`ops.assert_research_fetch_rights_v1`는 SOURCE_ACCESS capability를 찾은 뒤
model egress/use 등을 고정 `ALLOW`로 합성한다. `ops.record_research_fetch_v1`는
동일 capability UUID를 `raw.asset_rights_decisions.id`로 재사용하고 새 asset에
rights row를 INSERT한다. exact `(asset_id, revision, content_sha256,
decision_version, decision_sha256)` owner decision FK가 전달되지 않으며,
동일 capability로 두 번째 asset을 fetch하면 rights PK 재사용 충돌이 난다.
이는 source access 허가만으로 model-use rights를 만들고, 실제 DENY/UNKNOWN
asset을 ResearchArtifact로 승격시킬 수 있는 합성 경로다.

### R3-003 — legal hold deny-before-egress가 닫히지 않음 (P0)

capability preflight는 source ID의 `affected_ids`만 조회하고 asset/document
anchor를 잠그지 않는다. preflight와 gateway dispatch 사이에 hold가 활성화되면
외부 요청이 먼저 나갈 수 있으며 record 함수의 사후 재검사는 이미 발생한
egress를 되돌리지 않는다. serializable reservation/lock receipt 및 exact hold
anchor binding 증거가 없다.

### R3-004 — redirect chain이 per-hop typed receipt가 아님 (P1)

gateway는 redirect URL 문자열 배열만
`x-gurine-source-fetch-redirect-chain`으로 반환한다. authority response schema가
요구하는 각 hop `ordinal/status/fromOrigin/toOrigin/dnsDecisionSha256/
policyDecisionSha256`가 없고, gateway receipt digest도 chain을 해시하지 않는다.
`validate_target` 호출이 존재한다는 사실만으로 per-hop DNS/policy 결과의
cryptographic binding을 증명하지 못한다.

### R3-005 — source/evidence freeze가 아직 검증되지 않음 (P0)

현재 working tree에는 `MANIFEST.md`, `MANIFEST.sha256`, supplemental registry,
다섯 fixture 및 control-api source 변경이 unstaged 상태다. 따라서 기존
runtime receipt와 source digest가 동일 snapshot인지 확인할 수 없다. 전체
`sha256sum --check MANIFEST.sha256`와 `scripts/authority_tree_digest.py`,
clean-extraction archive parity를 최종 변경 후 다시 PASS시켜야 한다.

## Commands/evidence

- `python3 -B specs/agents/reference_harness.py` → `total=50`, `result=FAIL`.
- `python3 -B specs/agents/addendum-v2/validate_contracts.py --self-test` → PASS
  (schema self-test만 통과하며 provider fixture harness 성공을 의미하지 않음).
- `cargo test -p gurine-analysis-worker --lib` → 5/5 PASS; deterministic provider
  DB turn/rights/redirect integration을 실행하는 테스트는 포함하지 않는다.

위 P0/P1이 해결되고 harness, runtime receipt, manifest/tree/archive가 같은
final digest로 재생성되기 전에는 `AI_VERDICT: LGTM_NO_BLOCKING`을 발행할 수 없다.

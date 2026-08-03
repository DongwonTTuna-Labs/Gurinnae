# PdM 독립 리뷰 R12 — 2026-07-19 19:25 UTC

최신 clean-PostgreSQL flow artifacts(생성 18:59 UTC)를 authority-v13 SHA-256
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5` 기준으로
검토했다.

## 확인된 통과

- Flow 01–04 및 06–10 정상/negative branch PASS.
- Flow 03은 signal→triage→case→evidence→snapshot→independent review→publish의
  root/linkage, publication receipt와 stale signal/case no-mutation을 기록한다.
- Flow 04는 response token/OTP/draft/clean attachment/submit/receipt 및 replay
  no-mutation을 기록한다.
- Flow 06은 schema drift quarantine/mapping/backfill/checkpoint/dedupe/freshness
  lifecycle 및 negative branches를 기록한다.
- Flow 07–10의 semantic owner evidence가 존재한다.
- 10개 flow와 PDM-003의 correlation ID 및 sourceTreeDigest가 동일하다.

## Blocking finding

### PDM-R12-001 — Flow 05 negative branch가 권한 오류로 실패 (P0)

`flow-05-20260719.json`의 정상 correction/retraction chain은 도메인 receipt,
public API/download/notification readback을 갖지만, `normal.pass=false`다.
negative branch가 요구하는
`28000:submission_session_invalid_expired_or_out_of_scope` 대신
`42501:permission denied for function get_correction_receipt_session`을 관측했다.
현재 generator의 Flow-05 owner collector는 `SET SESSION AUTHORIZATION
gurine_migrator` 상태에서 해당 intake function을 호출하고, migration은 이 함수
EXECUTE 권한을 `gurine_submission_api`에만 부여한다. 이는 권한 경계에서의
정상 typed stale-session proof가 아니라 evidence harness 권한 오류다.

`pdm-003-observability-20260719.json` outer `pass=false`도 이 Flow-05 실패를
정확히 반영한다.

수정 조건: negative 호출을 authority가 허용한 `gurine_submission_api` 경계에서
실행하고, 이후 동일 request/revision/outbox count 불변 및 정확한 SQLSTATE
28000을 재생성·readback해야 한다. 권한을 과도하게 넓혀 validator를 통과시키는
방식은 허용하지 않는다.

## 판정

```text
PDM_VERDICT: CHANGES_REQUIRED
```


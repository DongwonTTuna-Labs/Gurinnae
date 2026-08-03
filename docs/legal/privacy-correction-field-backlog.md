# 개인정보 정정 필드 확장 백로그

상태: `BACKLOG_ONLY_NOT_AUTHORIZED`

이 문서는 개인정보 정정권의 향후 확장 후보를 기록하는 백로그다. 현재 실행 권위를
추가하지 않으며 API allowlist, 데이터베이스 owner, worker route 또는 공개 응답 스키마를
넓히는 근거로 사용할 수 없다.

## 현재 승인 범위

- 정확한 한 쌍: `RESPONSE` + `/partyName`
- 현재값 권위: response receipt에서 submission, immutable origin receipt, editorial response로
  이어지는 동일 정보주체 결속을 확인한 shared ACCESS projection
- 적용 권위: 인간 `APPROVE` 뒤 전용 response-domain workflow job이 version fence를 다시
  확인하고 immutable COMPLETE receipt를 기록하는 경로
- 공개 경계: `partyName` 원문은 공개 privacy status, command receipt, event, audit, error,
  log 또는 metric에 포함하지 않는다.

그 밖의 모든 `(targetObjectType, fieldPath)` 쌍은 현재
`PRIVACY_CORRECTION_TARGET_UNSUPPORTED` 422와 zero-write 대상이다.

## 확장 후보

다음 항목은 후보일 뿐이며 현재 지원되지 않는다.

- 정보주체가 자기 것으로 주장하는 연락 이메일
- 정보주체가 자기 것으로 주장하는 전화번호 등 연락 표시
- 표시명 이외의 직책·역할 표기 오류
- 개인정보 표시값의 명백한 오기

후보 이름만으로 물리 column, source relation, JSON Pointer 또는 적용 owner를 추론하지
않는다. 특히 연락 이메일을 response party name relation이나 communication endpoint에
임의로 매핑하지 않는다.

## 후보별 해제 조건

각 후보는 별도 권위 결정과 구현 검증으로 다음을 모두 충족해야 한다.

1. 정확한 `(object kind, JSON Pointer)` 한 쌍과 허용 값 형식·정규화·길이 계약
2. 요청 정보주체와 대상 객체를 결속하는 immutable receipt chain
3. ACCESS 출력과 정정 비교가 함께 사용하는 versioned projection 및 current-value digest
4. 요청값의 sealed storage, key revision, AAD와 plaintext-digest 책임 경계
5. 인간 `APPROVE`가 만드는 전용 typed job과 대상 domain의 version-fenced apply owner
6. stale version, changed digest, active legal hold, replay 및 concurrency의 zero-write 처리
7. immutable application/COMPLETE receipt와 raw 개인정보가 없는 event·audit·observability
8. 모든 미승인 쌍에 대한 422 zero-write 회귀 증거

## 계속 금지되는 범위

계약 금액·일자·낙찰 결과·기관/업체 식별 같은 조달 사실, 탐지 결과, 공개 판정,
publication decision, evidence 내용과 감사 기록은 개인정보 정정 명령으로 변경하지 않는다.
이 항목은 기존 공개 정정 절차와 각 도메인의 별도 권위 경계를 따른다.


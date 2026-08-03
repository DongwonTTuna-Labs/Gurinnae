# 백업 물리 폐기 절차

상태: `DRAFT_PROCEDURE_STUB`
정책 근거: `supervisor-decision-v1` (제품 정책 결정, 외부 법률 승인 아님)

이 절차는 자연인 엔티티 익명화 실행 뒤 1년이 지난 백업의 수동 물리 폐기 경계를
정의한다. 자동 삭제, 데이터베이스 완료 표시, 운영자 권한 또는 영수증 형식을 새로
만들지 않는다.

## 1. 만료 후보 인계

- `gurine_auditor` 경계에서 `ops.list_due_r6d_backup_disposals_v1(limit)`의 bounded 결과를
  내보낸다. 기존 백업 운영자가 직접 데이터베이스 역할을 가장하거나
  `gurine_migrator`·superuser를 사용해서는 안 된다.
- 목록 항목은 `backupDisposalDueAt`이 지난 익명화 실행 영수증이다. 실제 백업 artifact가
  존재하거나 아직 폐기되지 않았다는 증거가 아니며, 완료된 항목도 권위가 생기기 전에는
  반복해서 나타날 수 있다.
- 목록의 키·정렬·권한 계약은
  `specs/product/addendum-persistence-contracts.yaml`의
  `r6d_backup_disposal_due_inventory_contract`를 따른다.

## 2. 백업 범위 확인

- 기존 `infra/scripts` backup·restore 운영 경계가 관리하는 모든 권위 있는 저장 위치와
  복제본, version/PITR 보존 범위를 먼저 확인한다.
- due 항목과 실제 backup artifact의 대응을 현재 운영 인벤토리로 증명할 수 없거나 저장
  위치가 빠졌을 가능성이 있으면 폐기 완료를 주장하지 않고 중단한다.
- 활성 legal hold 또는 별도 보존 의무가 확인되면 해당 범위를 폐기하지 않는다.

## 3. 수동 폐기

- 자동 스케줄러나 데이터베이스 worker를 만들지 않는다. 기존 백업 운영 주체가 승인된
  운영 절차로만 물리 폐기를 수행한다.
- 허용 폐기 방법과 방법별 성공 증거가 아직 확정되지 않았으므로 이 문서는 명령이나
  방법 enum을 지정하지 않는다. 운영 권위가 없는 임의 삭제 명령을 실행해서는 안 된다.

## 4. 독립 부재 확인

- 폐기를 실행한 주체와 독립된 확인자가 모든 권위 있는 백업 위치에서 대상 artifact와
  보존 version/PITR 사본의 부재를 확인한다.
- 삭제 명령의 성공 종료만으로 부재를 확정하지 않는다. 확인 범위나 증거 형식을 확정할
  수 없으면 폐기 완료를 주장하지 않는다.

## 5. 폐기 완료 기록 경계 — operator-owned 유예

- 이 시스템에는 백업 물리 폐기 실행 영수증의 저장·서명 검증·완료 attestation 경로가 없다.
  따라서 due 목록, 수동 폐기 수행 또는 삭제 명령의 성공만으로 시스템은 대상 artifact의
  폐기 완료나 독립 부재 확인 완료를 주장하지 않는다.
- `BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY`가 `USER_INPUT_REQUIRED`인 동안에는 receipt
  schema, digest preimage, disposal-method enum, 데이터베이스 receipt relation·writer·role·
  capability, due 목록 완료 처리 또는 완료 항목 제외를 만들지 않는다.
- 이 문서는 자동 삭제, 데이터베이스 완료 표시, 운영자 권한 또는 외부 영수증 ABI의
  권위가 아니다.

## 6. 구현 재개에 필요한 operator-owned 입력

기록 경로 구현은 기존 backup·restore 운영자가 다음을 함께 확정한 뒤에만 별도 권위 결정으로
시작할 수 있다.

- 외부 append-only 영수증 저장소와 보존·접근 통제 경계
- 인증된 producer와 독립 부재 확인자의 신원·권한·서명 검증 규칙
- due execution receipt와 실제 backup artifact·복제본·version/PITR 사본의 정확한 식별 및
  N:M 대응
- 허용 물리 폐기 방법과 방법별 성공 증거
- 모든 권위 있는 저장 위치에 대한 독립 부재 확인 범위·증거·실패 처리
- exact receipt ABI, canonicalization/digest 또는 signature preimage, immutability·replay·
  정정 규칙

위 입력 전에는 외부 운영 기록의 존재·완전성·유효성을 이 시스템이 수신·검증·저장·표시하지
않는다.

## 중단 조건

다음 중 하나라도 충족하면 폐기 완료를 기록하지 않고 `OPEN_QUESTIONS`로 보고한다.

- backup artifact 식별과 due 항목의 대응을 증명할 수 없음
- 권위 있는 백업 위치 전체를 열거하거나 독립 확인할 수 없음
- legal hold 또는 다른 보존 의무의 부재를 확인할 수 없음
- `BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY`가 아직 확정되지 않음

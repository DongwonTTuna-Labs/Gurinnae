# ADR-003: 원본 데이터 보존과 public 재배포 분리

- Status: Accepted with legal-review checkpoints
- Date: 2026-07-10

## Context

재현성과 upstream 변경 증명을 위해 원본이 필요하지만, 공개 source에도 개인정보·저작권·삭제 사유가 있고 무기한 public mirror는 위험하다.

## Decision

1. RawObject는 private immutable storage에 저장한다.
2. Public access는 별도 sanitized asset 또는 source link/hash만.
3. publication을 지지한 raw는 마지막 material use 후 최소 7년 목표, 법률/개인정보 예외.
4. 아직 사용되지 않은 raw는 hot 90일, source/replay 가치에 따라 lower tier 최대 3년 기본.
5. public publication revision/correction은 indefinite.
6. model raw input/output는 90일 기본; structured/audit metadata는 더 길게.
7. response contact/token은 목적 종료 후 삭제; 내용은 case/evidence policy와 별도.
8. legal hold는 deletion을 중지.
9. 법적 삭제가 필요한 private payload는 cryptographic erase 가능하되 tombstone/audit 유지.

## Public mirror gate

- source license permits
- PII scan/redaction
- security harm review
- editorial necessity
- upstream update/removal policy

Gate가 없으면 public은 official URL, retrieved timestamp, checksum, approved excerpt만.

## Consequences

- storage cost 증가
- raw replay/forensic integrity 확보
- public/privacy risk 축소
- lifecycle tier and deletion jobs 필요

## Review triggers

- source terms change
- whistleblower uploads
- court/legal request
- storage cost threshold
- new data category/PII

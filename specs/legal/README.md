# R6d 법률 콘텐츠 권위

이 디렉터리는 공개 법률 콘텐츠의 구조와 근거 연결을 정의한다. 법률 자문이나 운영 조직의
승인을 가장하지 않는다. `supervisor-decision-v1`은 R6d 구현을 위한 제품 정책 권위이며,
외부 변호사 검토를 뜻하지 않는다.

- `privacy-notice.yaml`: 개인정보 처리방침 구조와 런타임 근거 계약
- `terms-of-use.yaml`: 이용약관 구조와 재배포 의무
- `law-enforcement-request-procedure.yaml`: 수사기관 요청 대응 절차 스텁
- `operator-owned-launch-inputs.yaml`: 사용자가 확정해야 하는 조직 항목
- `source-license-matrix.yaml`: 커넥터 카탈로그에서 결정적으로 생성되는 비런타임 검토표

백업 물리 폐기 운영자는 `docs/legal/backup-disposal-procedure.md`의 수동 절차와 중단
조건을 따른다. 정확한 외부 영수증 ABI가 확정되기 전에는 이 문서를 데이터베이스 완료
producer나 자동 삭제 권위로 해석하지 않는다.
`BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY`가 unset인 동안 시스템은 receipt producer,
completion attestation 또는 completed-item exclusion을 제공하지 않는다.

UI/서비스 통합용 폐쇄 envelope의 비런타임 기준은
`verification/generated-legal-content.json`이다. 각 문서는 `status`와 canonical
`sections[{id,heading,body}]`만 가지며 PUB-031 8개·PUB-032 6개 section ID를 중복 없이
고정한다. 런타임은 이 기준을 승인 데이터로 채우되, 미승인 값을 발명할 수 없다.

`source-license-matrix.yaml`과 `docs/legal/`의 `*-draft.md`,
`law-enforcement-request-procedure.md`, `operator-owned-launch-inputs.md`,
`source-license-matrix.md`는 `python -B scripts/generate_legal_content.py`로 생성한다.
`--check`는 저장된 결과와 다시 계산한 결과가 byte-identical인지 확인한다. 백업 폐기 절차는
운영 경계 문서이므로 생성 대상이 아니다.

보존 기간 표는 정적 파일에 복제하지 않는다. 공개 시점의 승인된
`ops.record_class_schedules` 행만 서버가 조회해 구성하며, 유효한 행이 없으면 개인정보
처리방침의 보존 표 상태는 `UNAVAILABLE`이고 문서도 공개 준비 완료로 간주할 수 없다.

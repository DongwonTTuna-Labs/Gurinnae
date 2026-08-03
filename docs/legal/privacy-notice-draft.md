# 개인정보 처리방침 구조 초안

> `scripts/generate_legal_content.py`가 생성한 비런타임 검토 문서입니다.
> 외부 법률 자문 또는 운영 승인을 뜻하지 않습니다.

상태: `DRAFT_UNPUBLISHED_LAUNCH_BLOCKED`  
정책 근거: `supervisor-decision-v1` (제품 정책 결정, 외부 법률 승인 아님)

감독자 결정 v1을 구현한 제품 정책 초안이며 외부 법률 자문 또는 승인 기록이 아닙니다.

## 섹션과 근거

| 섹션 | 근거 종류 | 근거 부재 처리 |
|---|---|---|
| 처리자 | `OPERATOR_INPUTS` | `BLOCK_PUBLICATION` |
| 정보 범주 | `APPROVED_RUNTIME_DATA` | `BLOCK_PUBLICATION` |
| 목적·법적 근거 | `APPROVED_RUNTIME_DATA` | `BLOCK_PUBLICATION` |
| 보존 | `RUNTIME_RELATION` | `BLOCK_PUBLICATION` |
| 처리위탁·국외 | `APPROVED_GOVERNANCE_EVIDENCE` | `OMIT_UNAPPROVED_ENTRY` |
| 권리 | `VERSIONED_POLICY` | `정책에 따름` |
| 보호 | `VERSIONED_POLICY` | `정책에 따름` |
| 변경 이력 | `DOCUMENT_REVISION_CHAIN` | `BLOCK_PUBLICATION` |

## 보존 표 런타임 계약

- 원천: `ops.record_class_schedules`의 유효하고 승인된 최신 revision
- 정적 기간·정적 행: 금지
- 승인 일정 0행의 표 상태: `UNAVAILABLE`
- 0행 처리: `UNPUBLISHED` / `FAIL_CLOSED`
- 사용자 메시지: 승인된 보존 일정이 없어 개인정보 처리방침을 공개할 수 없습니다.

보존 기간 표는 요청 시점의 승인 receipt에 묶인 행으로만 서버에서 생성합니다.
이 문서에는 기간 값을 복제하지 않습니다.

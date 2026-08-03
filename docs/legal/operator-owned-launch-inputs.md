# 사용자 소유 출시 입력

> `scripts/generate_legal_content.py`가 생성한 비런타임 검토 문서입니다.
> 외부 법률 자문 또는 운영 승인을 뜻하지 않습니다.

상태: `USER_INPUT_REQUIRED`  
정책 근거: `supervisor-decision-v1` (제품 정책 결정, 외부 법률 승인 아님)

| 항목 | 공개 전 필수 | 상태 | 설명 |
|---|---:|---|---|
| `OPERATING_LEGAL_ENTITY` | 예 | `USER_INPUT_REQUIRED` | 운영 법인명·등록 정보 |
| `PRIVACY_CONTROLLER` | 예 | `USER_INPUT_REQUIRED` | 개인정보처리자 법적 명칭 |
| `PRIVACY_OFFICER_OR_CPO` | 예 | `USER_INPUT_REQUIRED` | 개인정보 보호책임자 또는 담당 부서 |
| `PUBLIC_LEGAL_AND_PRIVACY_CONTACT` | 예 | `USER_INPUT_REQUIRED` | 공개 문의·권리행사 연락처 |
| `LIABILITY_AND_CYBER_INSURANCE` | 아니오 | `USER_INPUT_REQUIRED` | 적용 보험의 가입 여부·범위·증권 정보 |
| `EXTERNAL_KOREAN_COUNSEL_REVIEW` | 예 | `USER_INPUT_REQUIRED` | 대한민국 변호사 검토 결과와 유효 범위 |
| `BACKUP_PHYSICAL_DISPOSAL_RECEIPT_AUTHORITY` | 아니오 | `USER_INPUT_REQUIRED` | 기존 백업 운영자가 확정할 외부 append-only 영수증 저장소·생산자 인증·서명 ABI·artifact 식별 및 N:M 대응·허용 폐기 방법과 증거·독립 부재 확인 범위 |

값이 없는 항목은 이름·연락처·보험·검토 완료로 추정하거나 공개하지 않습니다.

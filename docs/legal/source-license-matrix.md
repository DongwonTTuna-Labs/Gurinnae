# 출처별 이용권 검토표

> `scripts/generate_legal_content.py`가 생성한 비런타임 검토 문서입니다.
> 외부 법률 자문 또는 운영 승인을 뜻하지 않습니다.

상태: `GENERATED_NON_RUNTIME_REVIEW_MATRIX`  
정책 근거: `supervisor-decision-v1` (제품 정책 결정, 외부 법률 승인 아님)

모든 이용권 차원은 별도 승인 receipt 전까지 `UNKNOWN`이며 허용을 뜻하지 않습니다.

| 커넥터 | 출처 | 권리 상태 | 차단 사유 | 공개 승인 |
|---|---|---|---|---:|
| `koneps-contracts` | https://www.data.go.kr/data/15129427/openapi.do | `REVIEW_REQUIRED` | `—` | 아니오 |
| `koneps-notices` | https://www.data.go.kr/data/15129394/openapi.do | `REVIEW_REQUIRED` | `—` | 아니오 |
| `koneps-bid-results` | https://www.data.go.kr/data/15129397/openapi.do | `REVIEW_REQUIRED` | `—` | 아니오 |
| `local-finance` | https://www.data.go.kr/data/15138709/openapi.do<br>https://www.data.go.kr/data/15138713/openapi.do | `REVIEW_REQUIRED` | `—` | 아니오 |
| `alio` | https://www.alio.go.kr/ | `REVIEW_REQUIRED` | `—` | 아니오 |
| `open-dart` | https://opendart.fss.or.kr/guide/main.do | `REVIEW_REQUIRED` | `—` | 아니오 |
| `pps-sanctions` | https://www.data.go.kr/data/15137996/fileData.do<br>https://data.g2b.go.kr/link/AISC001_01/?reptNm=UI-ADOAAA-017R | `BLOCKED` | `PPS_SANCTIONS_REUSE_RIGHTS_UNCONFIRMED` | 아니오 |
| `audit-results` | https://www.data.go.kr/ | `REVIEW_REQUIRED` | `—` | 아니오 |

커넥터 8개, operation 56개.
이 표는 커넥터 인벤토리이며 라이선스 허가서가 아닙니다.

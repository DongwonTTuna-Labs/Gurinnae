# 05. 최종 데이터 Source Catalog

권위 파일은 `specs/connectors/connector-catalog.yaml`과 각 `specs/connectors/<id>/` 디렉터리다.

| Connector | 범위 | Credential |
|---|---|---|
| `koneps-contracts` | 나라장터 물품·공사·용역·외자 계약 목록·상세·변경·삭제 | `DATA_GO_KR_SERVICE_KEY` |
| `koneps-notices` | 나라장터 물품·공사·용역·외자 공고·검색·변경·기초금액·참가제한 | `DATA_GO_KR_SERVICE_KEY` |
| `local-finance` | 지방재정 예산·결산·보조금 공개자료 | `DATA_GO_KR_SERVICE_KEY` |
| `alio` | 공공기관 기본·재무·조달 맥락 | source별 설정 |
| `open-dart` | 기업 식별·공시 맥락 | `OPEN_DART_API_KEY` |
| `audit-results` | 공식 감사 결과와 문서 | source별 설정 |

각 connector는 exact operation, request parameter, pagination, remote identity/revision, checkpoint, error mapping, field mapping, success/empty/quota/error/change/delete fixture를 갖는다.

합성 fixture는 구조 검증용이며 실제 live 성공 증거가 아니다. Production 활성화에는 공식 recorded payload fingerprint, schema mapping, quota probe, 이용조건 검토와 credentialed preflight receipt가 필요하다. 활성화는 configuration change이며 구현을 미루는 후속 단계가 아니다.

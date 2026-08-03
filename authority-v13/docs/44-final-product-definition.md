# 44. 최종 제품 정의

구린네는 세 개의 제품 surface와 세 개의 API, 공통 Rust domain/job/data platform으로 구성된다.

## Public Web

익명 사용자가 공공 계약·기관·업체·공개 조사 기록을 탐색하고,
근거와 한계를 이해하며 정정·구독 절차로 진입한다.

## Review Console

조사자·편집자·독립 검토자·운영자가 signal부터 publication까지 처리한다.
모든 command는 권한·target·reason·audit를 따르며, `assurance_level: STEP_UP` command만 bounded recent reauthentication을 요구한다. UI destructive confirmation은 별도 분류다.

## Response Portal

기관·업체가 제한된 token과 이메일 검증으로 소명 요청을 확인하고,
질문별 답변과 첨부를 제출하며 공개 동의 범위를 검토한다.

## 제품 성공의 기준

- 사용자가 30초 안에 anomaly와 wrongdoing을 구분한다.
- 기자가 공개 revision과 계산을 재현·인용한다.
- 조사자가 다음 필수 작업과 blocker를 즉시 안다.
- 당사자가 무엇이 공개될 수 있는지 제출 전에 이해한다.
- 정정과 철회가 원 기록을 지우지 않고 명확히 연결된다.
- 운영자가 source·job·비용·incident를 안전하게 중단·복구한다.

## 최종 범위 제외

- 익명 공개 폭로 게시판
- 댓글·좋아요·인기순위
- 기관·업체 부패 점수
- 수사기관 역할 대체
- 자동 명예훼손성 결론
- 돈을 받고 조사 제거

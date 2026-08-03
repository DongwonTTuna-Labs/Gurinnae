# ADR-015: 기관 순위와 참여형 게임화 금지

- 상태: Accepted
- 날짜: 2026-07-10

## Context

기관·업체의 공개 사건 수나 가격 배수를 순위화하면 source coverage, 기관 규모, 계약 유형, rule 적용 차이를 단일 도덕 점수로 축소한다. 댓글·좋아요·화제순은 사실 검증보다 분노와 확산을 최적화할 수 있다.

## Decision

초기 및 현재 승인 범위에서 다음을 금지한다.

- 부패/구림/위험 점수
- 기관·업체 leaderboard
- 내부 signal priority 공개
- click/like/share 기반 사건 정렬
- 댓글, reaction, follower count
- streak, badge, 포인트
- “AI confidence” 공개
- 가장 높은 가격 배수 top list

허용:

- coverage와 denominator가 있는 descriptive statistics
- 사용자가 명시적으로 선택한 날짜·금액 정렬
- 상태·방법론·지역 filter
- 편집 기준이 공개된 최근 기록 selection
- 설명·정정·철회 포함

## Consequences

- 선정적 viral growth를 포기
- 신뢰·공정성·법적 안전성 강화
- 기관 비교는 더 많은 맥락과 설명 필요
- growth metric을 이해·재현·정정 품질로 전환

## 변경 조건

순위 또는 community 기능은 별도 ADR, 법률 검토, bias/coverage 연구, 사용자 연구, threat model, moderation 운영 계획 없이는 도입할 수 없다.

## Fitness tests

- UI label과 API에 corruption score field 없음
- 기관 list 기본 정렬이 case count 아님
- 홈 selection이 click-through rate를 입력으로 사용하지 않음
- public analytics가 trending endpoint를 만들지 않음

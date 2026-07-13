# ADR-014: Evidence-first 사건 상세 정보 위계

- 상태: Accepted
- 날짜: 2026-07-10
- 관련 screen: `PUB-004`, `CAS-014`

## Context

가격 배수, AI 요약, 선정적 제목이 사건 상세 상단을 차지하면 사용자가 이상 징후를 비리 확정으로 오인할 수 있다. 반대로 한계를 각주에 숨기면 형식적으로는 공개했지만 실제 이해를 방해한다.

## Decision

공개 사건 상세와 내부 public preview의 상단 순서를 고정한다.

1. 현재 상태와 revision/freshness/correction
2. 관찰된 사실
3. 가장 중요한 미확인 사항
4. 기관·업체 소명
5. 비교 맥락과 결정적 계산
6. 반대 근거
7. evidence/provenance
8. 방법론·timeline·revision

가격 배수나 chart를 독립적인 hero로 사용하지 않는다. AI summary는 공개 surface에 별도 권위로 표시하지 않는다.

## Consequences

- 정보 이해와 법적 안전성 향상
- sensational engagement는 낮을 수 있음
- 더 많은 content design과 summary 품질 관리 필요
- mobile에서도 같은 순서를 유지해야 함

## Fitness tests

- first viewport에 상태와 중요한 미확인 접근 가능
- response가 있으면 비교 chart 이전 또는 동등한 우선순위
- 모든 metric에 unit/cohort/caveat
- correction/retraction banner가 모든 revision에 표시
- 30초 comprehension research 통과

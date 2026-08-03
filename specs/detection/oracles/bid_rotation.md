# BID_ROTATION Independent Reference Oracle

Version: `1.0.0`

## Operational state

`BLOCKED`. 현재 승인된 KONEPS 개찰·낙찰 원천에는 공고별 전체 참가업체와 입찰가가
구조화된 행으로 존재하지 않는다. 운영 materializer는 이를 추론하거나 `opengCorpInfo`
문자열을 분해하지 않는다. 공식 구조화 원천, 권리 검사, 정규화 계약, 스냅샷 coverage
증명이 모두 갖춰져야 `participant_source.status=STRUCTURED_COMPLETE`를 만들 수 있다.

오라클의 `STRUCTURED_COMPLETE` 입력은 알고리즘을 검증하는 테스트 fixture 권위일 뿐이며
운영 seed나 원천 존재 주장이 아니다.

## Required input policy

모든 필드는 입력마다 필수이며 기본값과 활성 운영 seed는 없다.

```yaml
minimum_notice_count: integer >= 3
window_days: integer >= 0
minimum_bidders_per_notice: integer >= 3
minimum_distinct_winners: integer >= 2
cluster_metric: LOSING_BID_RANGE_BPS
cluster_tolerance_bps: decimal >= 0
currency: exact nonempty code
tie_handling: BLOCK
```

30-case fixture의 기본 profile은 `minimum_notice_count=3`, `window_days=60`,
`minimum_bidders_per_notice=3`, `minimum_distinct_winners=3`,
`cluster_tolerance_bps=200`, `currency=KRW`, `tie_handling=BLOCK`이다. 음성·경계
케이스는 notice/bidder/winner 최소값과 window/tolerance를 케이스 안에서 명시적으로
바꾼다. 모든 케이스가 값을 직접 포함하며 어느 수치도 운영 정책이 아니다.

## Canonical input

- `participant_source.status`
- `observation_period_complete`
- `notices[]`: `id`, `agency_id`, `noticed_at`, 세 coverage flag,
  `winner_supplier_id`, `participants[]`
- `participants[]`: `supplier_id`, `bid_amount`, `currency`

업체 표기명은 identity로 사용하지 않는다. 자연인 데이터, 점수, 순위, 확률, 가족·친족
관계는 입력에 없다.

## Exact formula

1. source가 `STRUCTURED_COMPLETE`가 아니거나 기간·참가자·승자·가격 coverage가 불완전하면
   `BLOCKED`.
2. 각 공고의 업체 ID가 중복되지 않고, 낙찰자는 참가자 집합에 있으며 유일 최저가여야 한다.
   최저가 동률은 `tie_handling=BLOCK`에 따라 `BID_TIE`.
3. 공고를 `(noticed_at, id)`로 정렬한다.
4. 모든 공고의 기관과 참가업체 ID 집합이 동일해야 한다.
5. 공고 수·공고별 최소 참가자 수·서로 다른 낙찰자 수가 입력 정책 이상이고,
   인접 공고의 낙찰자가 달라야 한다.
6. 최초·최종 공고일 차이가 `window_days` 이하여야 한다.
7. 각 공고의 `LOSING_BID_RANGE_BPS`를 다음처럼 계산한다.

   `(탈락 최고가 - 탈락 최저가) / 탈락 최저가 * 10000`

8. 모든 공고 중 최대 range가 `cluster_tolerance_bps` 이하면 `SIGNAL`; 아니면
   `NO_SIGNAL`.

참가자 집합·기관 불일치, 반복 낙찰자, 임계 수 미달, 기간 초과, 가격 비군집은 완전한
입력에서의 오탐 방지 음성 조건이므로 `NO_SIGNAL`이다.

## Blockers

- `REQUIRED_FIELD_MISSING`
- `INVALID_POLICY`
- `STRUCTURED_PARTICIPANT_SOURCE_UNAVAILABLE`
- `PERIOD_COVERAGE_INCOMPLETE`
- `PARTICIPANT_SET_INCOMPLETE`
- `PARTICIPANT_IDENTITY_AMBIGUOUS`
- `WINNER_INCOMPLETE`
- `WINNER_PRICE_INCONSISTENT`
- `PRICE_COVERAGE_INCOMPLETE`
- `CURRENCY_MISMATCH`
- `DUPLICATE_NOTICE_ID`
- `BID_TIE`

## Exact output

`outcome`, `blockers`, metrics, sorted `included_ids`, sorted `excluded_ids`,
`input_hash`, `result_hash`. Metrics는 다음과 같다.

- `notice_count`
- `minimum_bidder_count`
- `distinct_winner_count`
- `window_span_days`
- `maximum_losing_bid_range_bps` (4자리 반올림)
- `same_agency`
- `same_participant_set`
- `winners_rotate`
- `losing_prices_clustered`
- `cluster_metric`
- `currency`

## Metamorphic invariants

- 공고·참가자 입력 순서는 결과와 hash 이외의 판정을 바꾸지 않는다. 입력 hash는 입력
  canonical JSON 자체를 증명하므로 순서가 바뀌면 달라질 수 있다.
- 업체 한 곳을 다른 ID로 바꾸면 exact participant set 판정이 해제된다.
- coverage false는 `NO_SIGNAL`로 평탄화되지 않는다.
- `publication_claim_allowed=false`; 결과는 이상징후 트리아지에만 쓴다.

## Executable authority

`python3 specs/detection/reference_evaluator.py`가
`specs/detection/evals/bid_rotation.jsonl`의 30개 concrete case를 독립 평가한다.
Rust 결과는 canonical JSON 기준 전체 expected object와 일치해야 한다.

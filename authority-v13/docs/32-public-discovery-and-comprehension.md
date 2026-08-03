# 32. 공개 탐색과 사건 이해 경험

## 1. 목표

공개 웹의 목표는 사용자를 분노하게 만드는 것이 아니라, 공개된 사건을 책임 있게 이해하고 검증할 수 있게 하는 것이다. 모든 공개 화면은 다음 질문에 답해야 한다.

- 무엇이 확인되었는가?
- 무엇이 계산되었는가?
- 무엇이 아직 확인되지 않았는가?
- 기관·업체는 무엇이라고 답했는가?
- 이 기록은 얼마나 최신인가?
- 원본과 계산을 어디서 확인할 수 있는가?
- 이후 정정되거나 철회되었는가?

## 2. 홈

홈은 “가장 수상한 기관”을 나열하지 않는다.

### 정보 우선순위

1. 서비스 정의와 한계
2. 통합 검색
3. 최근 공개된 기록
4. 최근 설명 완료·정정·철회
5. 데이터 coverage와 source freshness
6. 방법론 소개
7. 구독과 운영 투명성

### 홈 카드의 균형

최근 기록 영역은 상태별로 균형을 유지한다.

- `PUBLISHED_AS_ANOMALY`
- `EXPLAINED`
- `OFFICIALLY_CONFIRMED`
- `CORRECTED`
- `RETRACTED`

트래픽이나 가격 배수만으로 홈 노출을 결정하지 않는다. 편집 선택이 있는 경우 selection policy와 기간을 공개한다.

### 첫 방문자 이해

첫 화면은 다음 문구를 포함해야 한다.

> 구린네는 공개자료에서 조사할 가치가 있는 이상 징후를 찾습니다. 이상 징후는 비리나 범죄의 확정이 아닙니다.

합성 demo 환경에서는 실제 운영 서비스와 혼동되지 않는 persistent banner를 표시한다.

## 3. 통합 검색

### 검색 의도

사용자는 다음 중 하나를 찾는다.

- 특정 기관 또는 업체
- 계약 번호·사업명
- 특정 사건
- 품목 또는 방법론
- 정정된 기록

자동완성은 객체 유형과 공식 명칭을 표시한다. 업체·기관 이름이 유사할 때 주소나 지역 등 구분 정보가 필요하다.

### 결과 설명

검색 결과는 왜 일치했는지 보여준다.

```text
업체명 일치
계약 제목 일치
사건 요약 일치
원문 전체 텍스트 일치
```

공개되지 않은 내부 자료가 검색 hit에 영향을 주어 존재를 암시해서는 안 된다.

## 4. 목록 화면

### 사례 목록

각 카드/행:

- 현재 상태
- 제목
- 1문장 관찰 사실
- 가장 중요한 미확인 항목
- 기관·업체
- 계약일·공개일
- 방법론
- response 상태
- source freshness
- correction 존재 여부

금지:

- 충격도
- AI confidence
- 부패 확률
- 내부 priority
- “TOP 10 구린 기관”

### 계약 목록

계약 목록은 이상 신호가 없는 계약도 coverage 범위에서 검색할 수 있어야 한다. 사건이 없는 계약을 “정상”이라고 표시하지 않는다.

### 기관·업체 목록

기관·업체 index는 가나다·검색·지역·유형 탐색을 제공한다. 사건 건수로 기본 정렬하지 않는다.

## 5. 사건 상세

### 5.1 Page header

필수:

- 상태 badge와 쉬운 설명
- publication revision
- 최초 공개일·최근 수정일
- source freshness
- correction/retraction banner
- 제목
- 요약
- share/citation 기능

제목은 편집 기준을 따른다.

좋은 예:

> 가상새빛시청 안전모 계약에서 비교군보다 높은 단가가 관찰됨

나쁜 예:

> 세금 5배 폭리? 수상한 안전모 계약의 충격적 진실

### 5.2 Known / Unknown / Response

상단 3영역은 사건 이해의 핵심이다.

**확인된 사실**

- 원본 계약의 금액·수량·기간
- 결정적 계산
- 검증된 source 문장

**중요한 미확인**

- 유지보수 포함 여부
- 비공개 부속 규격
- 동일 모델 여부

**기관·업체 소명**

- 응답 여부
- 제출일
- 공개 승인된 원문 또는 요약
- 편집자가 독립 검증하지 못한 주장임을 필요한 경우 표시

응답이 없으면 “사실을 인정했다”가 아니라 다음처럼 표시한다.

> 2026년 7월 3일 소명을 요청했으며 2026년 7월 10일 현재 답변을 받지 못했습니다.

### 5.3 Metric with context

가격 배수는 단독 hero number가 아니다.

```text
대상 단가          2,400,000원
비교군 중앙값        480,000원
계산 비율                5.0배
비교 계약 수              12건
비교 기간        2025-01-01~2025-12-31
제외 조건        단위·VAT·묶음 구성 불명
```

금액에 통화, VAT 기준, 단위, 포함 범위를 붙인다.

### 5.4 비교 시각화

- 분포 chart + 접근 가능한 table
- 대상 계약 위치
- median/IQR
- 포함·제외 계약 수
- filter와 cohort version
- outlier가 차트 scale을 왜곡하면 대체 표현
- hover에만 의존하지 않음

### 5.5 Evidence

claim마다 citation marker가 있다. drawer 또는 dedicated section은 다음을 제공한다.

- evidence title/type
- source owner
- retrieval time
- content hash
- page/row/field locator
- quote는 필요한 짧은 범위
- 공개 제한 사유
- archived copy availability
- verification status
- 관련 claim

### 5.6 반대 근거와 대안 설명

동일한 시각적 중요도로 표시한다.

- 사양 차이
- 설치·교육·보증
- 군용·의료·보안 인증
- 소량 주문
- 계약 취소·변경
- source 오류
- identity ambiguity

### 5.7 Timeline과 revision

timeline은 사건의 변화를 보여준다.

- source 수집
- signal 탐지
- 소명 요청
- 응답
- 공개
- 정정
- 공식 감사 결과

내부 조사 이벤트는 공개 승인된 항목만 포함한다.

## 6. 기관 상세

목표는 기관의 계약 맥락을 제공하는 것이다.

### 필수 섹션

- 공식 identity·기관 유형·관할
- coverage 기간과 source
- 관측된 계약 수·금액
- 공개 사건 상태별 분포
- 최근 계약
- 최근 공개 사건
- 설명 완료·정정 사례
- 사용된 방법론
- 데이터 한계

비교를 제공할 때:

- 유사 기관 cohort 정의
- coverage 차이
- 단순 raw count 대신 denominator
- 순위 금지
- 작은 표본 경고

## 7. 업체 상세

- 공식 명칭·사업자 식별정보의 공개 가능한 범위
- 명칭·주소 변경 이력
- entity resolution confidence는 내부용; 공개에서는 확인 상태와 한계 표현
- 관측된 공공계약
- 기관 분포
- 공개 사건·설명·정정
- 관련 업체는 공식 관계가 확인된 경우만
- 동일 주소만으로 “관계사” 단정 금지

## 8. 계약 상세

계약 상세는 사건이 없어도 존재한다.

- source 계약 ID
- agency/supplier
- 금액·기간·방식
- line items
- 변경 계약
- 입찰·낙찰 연결
- raw source·retrieval
- normalized field provenance
- 관련 공개 사건
- 데이터 한계

“이상 신호 없음”을 “문제 없음”으로 표현하지 않는다.

## 9. 방법론·coverage·source

### 방법론

비전문가 설명과 technical appendix를 분리한다.

- 무엇을 찾는 규칙인가
- 필요한 데이터
- 계산
- trigger
- blocker
- 알려진 오탐
- rule version
- 평가 결과
- 변경 이력

### Coverage

- 포함 source
- 기간
- 기관 범위
- known gaps
- stale source
- 처리 latency
- raw redistribution 제약

### Source detail

- 운영 기관
- 데이터 성격
- 접근 방법
- 갱신 주기
- last successful sync
- schema version
- known quality issues
- license/terms
- 관련 방법론

## 10. 정정과 철회

정정 index를 별도 제공한다.

각 기록:

- 대상 사건·revision
- 오류 유형
- 이전 내용 요약
- 변경 내용
- 이유
- 적용 시각
- 승인 절차
- 영향 데이터/API

철회 사건은 검색 결과에서 사라지지 않고 상태가 우선 표시된다.

## 11. 공유·인용

- 최신 revision 공유
- 특정 revision 고정 링크
- claim/evidence fragment 링크
- citation text 복사
- machine-readable metadata
- 공유 preview 이미지에는 선정적 가격 배수 대신 상태와 제목
- correction 후 오래된 공유 URL에 최신 notice

## 12. 알림·구독

주제:

- 특정 사건
- 기관
- 업체
- 방법론
- 정정 전체
- source incident(전문 사용자)

알림 유형:

- 새 공개
- 소명 추가
- 정정/철회
- 공식 확인
- 방법론 version change

기본 빈도는 즉시가 아니라 사용자 선택이며, 사건 상태를 과장하는 제목을 금지한다.

## 13. 공개 화면 acceptance

- 상태를 보지 않고 title만으로 위법 확정으로 오인할 표현이 없다.
- 모든 핵심 metric에 unit·scope·cohort가 있다.
- 중요한 미확인 항목이 fold 아래 숨지 않는다.
- response가 없음을 유죄 추정으로 쓰지 않는다.
- source stale가 해당 숫자와 함께 표시된다.
- chart와 동등한 table이 있다.
- correction/retraction이 모든 관련 URL에서 발견 가능하다.
- 공개 페이지는 내부 priority·agent confidence·editor note를 포함하지 않는다.

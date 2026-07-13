# 03. 편집·공개 정책

## 1. 정책 목적

이 문서는 신호가 탐지된 이후 무엇을 조사하고, 어떤 근거가 있어야 어떤 표현으로 공개할 수 있으며, 대상의 소명·정정·철회를 어떻게 처리하는지 정한다. 모든 public API와 UI는 이 정책을 강제해야 한다.

이 문서는 법률 자문을 대체하지 않는다. 실제 공개는 `docs/12-legal-and-compliance.md`의 법률 게이트와 함께 적용한다.

## 2. 기본 명제

1. 이상 신호는 사실이 아니라 분석 결과다.
2. 높은 가격은 위법성의 증거가 아니다.
3. 공식 source도 오류·정정·중복을 포함할 수 있다.
4. 모델의 confidence는 사실의 진실도나 부패 확률이 아니다.
5. 공개의 책임은 승인한 사람에게 있다.
6. 정정 가능성은 공개 전 검증을 줄이는 면허가 아니다.

## 3. 편집 단위

### SourceDocument

공식 API 응답, 공시 파일, 웹 페이지 snapshot 등 원본.

### Evidence

SourceDocument의 특정 구간·필드 또는 검증된 독립 자료. `SUPPORTS`, `CONTRADICTS`, `CONTEXT`, `NEUTRAL` stance를 가진다.

### Claim

독자가 참·거짓을 평가할 수 있는 구체적 문장. 수치·기간·대상·비교 범위를 명확히 한다.

### Interpretation

Claim에서 파생된 제한된 해석. “설명이 필요하다”, “비교군 대비 이례적이다” 수준이며, 형사·도덕적 유죄를 추론하지 않는다.

### PublicationRevision

승인된 claim, methodology, response, correction note를 묶은 immutable 공개 snapshot.

## 4. 공개 상태 표기

| Public label | 의미 | 금지된 오해 |
|---|---|---|
| 이상 징후 공개 | 설명되지 않은 분석 신호와 근거를 공개 | 위법 확정 아님 |
| 합리적 설명 확인 | 초기에 보인 차이에 설명이 확인됨 | 기관 면책 판정 아님 |
| 공식기관 검토 중 | 감사·수사·의회 등 공식 절차 확인 | 혐의 인정 아님 |
| 공식 지적 확인 | 공식 감사결과 등이 문제를 명시 | 형사 유죄와 동일 아님 |
| 정정됨 | 이전 공개의 일부가 수정됨 | 과거 내용이 현재 유효하지 않을 수 있음 |
| 철회됨 | 핵심 근거가 무너져 현재 게시를 철회 | 흔적 삭제 아님 |

Internal state 명칭은 case lifecycle을 따른다.

## 5. 공개 최소 요건

모든 standard anomaly publication은 다음을 만족해야 한다.

### 5.1 Identity

- 기관은 공식 코드 또는 2개의 독립 공식 식별로 확정
- 업체는 사업자/법인 식별자 exact match 또는 편집 검증
- 동명이인·상호 변경·합병 후보가 남으면 public 식별 보류

### 5.2 Source and provenance

- 최소 1개의 공식 primary source
- 모든 핵심 수치에 field/page provenance
- source retrieval time와 checksum
- 원본이 수정되었는지 확인한 시각

### 5.3 Analytical validity

- 규칙 버전과 계산 재현 통과
- 단위·통화·VAT·수량 일치
- 가격 비교이면 bundle/spec/date/warranty/installation/maintenance 검토
- 비교군 최소 수 또는 부족 이유 명시
- excluded observations와 reason 기록

### 5.4 Counter-hypothesis

최소 한 명의 investigator 또는 skeptic이 합리적인 대안 설명을 검토한다.

예:
- 설치·교육·보증 포함
- 소량·긴급 조달
- 인증·보안·환경 내구성
- 제품 세대·모델 차이
- 환율·원자재 급등
- 장기 유지보수 계약
- 단위/세금 표기 오류
- 계약 변경/취소/중복 공시

### 5.5 Right of reply

- 기관과 업체에 핵심 claim, 근거, response 방법, deadline 제공
- 표준 대기: verified delivery 후 5 business days
- 최소 2개의 합리적 delivery attempt 또는 공식 contact channel 1회 + reminder
- 무응답 시 “기한 내 답변을 받지 못함”만 표기
- 긴급 예외는 public safety/자료 소실 등 명시적 사유와 legal/editorial 승인

### 5.6 Human review

- 작성자와 다른 editor 1명 이상
- 업체 실명 또는 reputational risk가 있으면 독립 editor 2명
- high-risk flag가 있으면 legal reviewer
- 승인 content hash가 publish content hash와 일치

### 5.7 Wording and uncertainty

- 관찰 사실과 해석을 분리
- 확인되지 않은 항목 명시
- “왜 이 차이가 생겼는지는 공개자료만으로 확인되지 않았다” 표현 허용
- 무응답, 삭제, 늦은 답변을 죄책의 증거로 해석 금지

## 6. Evidence 등급

| Tier | 예 | 사용 |
|---|---|---|
| A | 법령, 공식 API, 계약서, 감사결과, 법원 판결 | 핵심 사실의 primary evidence |
| B | 다른 공식 시스템, 기관 보도자료, 공시 재현 | 독립 교차검증 |
| C | 제조사 사양·가격표, 업체 공식 설명 | 제품/구성 맥락; 독립성 한계 표시 |
| D | 신뢰할 수 있는 언론·연구 보고서 | 배경·추가 조사; primary 대체 불가 |
| E | 제보·포럼·SNS·검색 snippet | lead only, 단독 공개 근거 불가 |
| F | AI 생성 요약·추론 | evidence 아님 |

표준 publication은 최소 Tier A 1개를 요구한다. 가격 차이 claim은 비교 가능한 Tier A/B observation 또는 검증된 C를 복수로 요구한다.

## 7. Claim 작성 규칙

### 7.1 Claim은 한 문장에 하나의 검증 가능한 사실

나쁜 예:

> 가람시가 수상한 업체와 비싼 계약을 반복해 유착이 의심된다.

좋은 예:

> 가람시는 2026년 1월부터 6월까지 한빛장비와 동일 품목군의 수의계약 7건을 체결했으며, 합계 계약금액은 1억 8천만 원이다.

별도 해석:

> 동일 기관·업체·품목군에서 짧은 기간 반복 계약이 발생해 계약 분할 또는 반복 수의계약 여부를 추가 확인할 필요가 있다. 공개자료만으로 계약 목적의 독립성은 확인되지 않았다.

### 7.2 상대 비교에는 분모를 표시

- “평균보다 비쌌다” 금지
- “사양·수량·VAT 기준을 통과한 11건의 중앙값 72,000원 대비 268,000원”처럼 명시
- mean보다 outlier에 강한 median을 기본 사용
- 비교군이 작으면 n과 한계를 전면 표시

### 7.3 시간 기준

가격·업체상태·source는 시점에 따라 변한다. “현재” 대신 정확한 관찰일을 사용한다.

### 7.4 인과 추론 금지

계약 집중과 친분, 고가와 리베이트, 변경계약과 의도 사이 인과를 evidence 없이 연결하지 않는다.

## 8. 제목·요약·카피 정책

### 허용 제목

- “동일 사양 공공계약 중앙값의 3.7배: 가람시 안전장비 계약”
- “30일 안에 유사 계약 4건: 계약 목적의 독립성 확인 필요”
- “설치·교육 포함 확인으로 가격 차이 설명됨”

### 금지 제목

- “가람시, 세금 5배로 해먹었나”
- “AI가 잡아낸 100% 비리”
- “부패 도시 1위”
- “무응답으로 의혹 인정”

### 요약 필수 구성

1. 무엇이 관찰되었나
2. 어떤 source와 기간인가
3. 어떻게 비교했나
4. 무엇이 아직 모르는가
5. 기관·업체는 무엇이라고 답했나
6. 이 결과가 의미하지 않는 것은 무엇인가

## 9. 개인 실명과 개인정보

기본 공개 단위는 기관과 법인/사업자다. 개인 이름은 다음 모두 충족 시에만 고려한다.

- 공식 문서에서 해당 역할과 행위가 공개
- 사건 이해에 실질적으로 필요
- 공익성이 사생활 침해보다 큼
- 단순 담당자·연락처가 아님
- legal review와 two-person approval
- 주소, 전화, 이메일, 생년월일 등 불필요 정보 제거

공무원 담당자 이름이 계약 문서에 있다는 이유만으로 case 페이지에 검색·색인하지 않는다.

## 10. 업체 관계·네트워크 표현

- 같은 주소·대표자·전화번호는 “공유된 공개 식별자”라고만 표시
- 관계회사, 페이퍼컴퍼니, 차명, 유착이라는 단정 금지
- fuzzy match는 public graph에 표시하지 않음
- 법인 등기·공식 공시 또는 명시적 verified relation이 필요
- 개인 가족관계 추적은 scope 밖

## 11. 공식 확인의 처리

### 감사·행정기관

공식 보고서의 정확한 조치·지적 문구와 범위를 요약한다. “공식 지적”이 형사 범죄 확정이라고 확대하지 않는다.

### 수사·기소

수사 개시, 송치, 기소, 판결을 구분한다. 무죄추정과 현재 절차 상태를 표시한다.

### 법원

판결심급, 선고일, 확정 여부를 표시한다. 판결문 없는 보도만으로 확정 상태를 만들지 않는다.

## 12. 소명 정책

### 12.1 요청 내용

- 대상 contract/case ID
- 검토 중인 exact claims
- source와 계산 설명
- 질문 목록
- 제출 deadline/timezone
- 공개·개인정보 처리 방식
- 정정·연장 요청 contact

### 12.2 응답 처리

- 원문을 immutable하게 저장
- 사실 자료와 의견을 분리
- 공개 가능 범위와 redaction 확인
- 중요한 반박은 본문과 같은 가시성으로 반영
- 긴 응답은 충실히 요약하고 원문 접근 제공
- 모욕·개인정보·악성 payload는 redaction 가능하며 이유 기록

### 12.3 연장

합리적인 자료 준비 사유가 있으면 기본 3 business days 연장 가능. 반복 지연은 editor가 결정하며 무응답을 유죄 근거로 쓰지 않는다.

## 13. 공개 승인 행렬

| Case risk | 최소 승인 | response | legal |
|---|---|---|---|
| LOW aggregate/statistical | editor 1 | 필요 시 | 선택 |
| MEDIUM named supplier/agency | editor 2 | 필수 | 위험표현 시 |
| HIGH individual/criminal/election/security | editor 2 + executive | 필수 | 필수 |
| PROHIBITED | 불가 | 해당 없음 | 공개 불가 |

AI, developer, sales는 approval actor가 될 수 없다.

## 14. 정정·철회

### 14.1 Correction severity

- MINOR: 오탈자, 링크, 의미 불변
- MATERIAL: 수치·비교군·해석·response 변경
- CRITICAL: 대상 오인, 핵심 근거 오류, 결론 역전, 개인정보 노출

### 14.2 SLA 목표

- privacy/security emergency: 즉시 임시 차단 가능, 4시간 내 책임자 검토
- critical factual report: 1 business day 내 초기 판단·banner
- material: 3 business days 내 조사 목표
- minor: 5 business days

### 14.3 처리

- old revision 유지
- current page 상단에 correction notice
- 무엇이 왜 바뀌었는지 정확히 표시
- material/critical은 구독자 notification
- 외부 syndicated copy가 있으면 정정 전달 시도

### 14.4 Retraction

핵심 근거가 무너졌거나 대상이 잘못되었거나 공개가 법적·안전상 부적절하면 철회한다. URL을 조용히 404로 만들지 않고, 가능한 범위에서 철회 이유와 날짜를 남긴다. 개인정보 긴급 상황에서는 본문을 즉시 비공개하고 최소 notice만 유지할 수 있다.

## 15. 삭제·비공개 요청

요청이 왔다는 이유만으로 삭제하지 않는다. 다음을 평가한다.

- 사실 오류
- 개인정보 최소화
- source license/법적 의무
- 제보자·피해자 안전
- 공식 기록의 변경
- 공익 지속성
- 과도한 검색 노출

가능한 대안:

- correction
- personal field redaction
- search engine noindex
- attachment 비공개 + checksum 유지
- public summary 축소
- full retraction

모든 결정은 reason code와 reviewer를 기록한다.

## 16. 공개 게이트 의사코드

```text
can_publish(case, draft):
  require case.state == READY_TO_PUBLISH
  require draft.content_hash == approved_content_hash
  require all claims have verified evidence refs
  require identity confidence == VERIFIED for named entities
  require reproducibility check == PASS
  require no unresolved blocking conditions
  require response window complete or approved exception
  require privacy scan == PASS
  require source license review == PASS
  require editor approvals satisfy risk matrix
  require legal approval if legal_required
  require no reviewer authored and solely approved same claims
  require public projection dry-run == PASS
  return true
```

어느 하나라도 실패하면 publication command는 atomic하게 거부되고 audit event를 남긴다.

## 17. 외부 신고·기관 전달

구린네가 국민권익위원회, 감사원, 수사기관 등에 자료를 전달하는 기능은 public publication과 별도다.

- 자동 전달 금지
- evidence package와 법적 근거 검토
- 제보자/개인정보 최소화
- 공식 접수 ID와 전달 범위 기록
- 전달 사실 공개 여부 별도 검토
- 접수는 위법성 확인이 아님을 표시

## 18. 정책 위반 incident

오승인, provenance 단절, 개인정보 노출, 잘못된 대상 공개가 발견되면 `docs/14-launch-and-incident-response.md`의 editorial incident 절차를 즉시 시작한다. 성장·SEO·법적 위협 대응보다 정확한 임시 차단과 영향 범위 확인이 우선이다.

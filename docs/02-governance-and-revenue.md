# 02. 거버넌스와 수익모델

## 1. 목적

구린네의 가장 큰 자산은 코드나 모델이 아니라 “돈과 정치적 압력이 공개 판단을 바꾸지 않는다”는 신뢰다. 이 문서는 소유·편집·영업·후원·이해상충의 경계를 정하고, 지속 가능한 수익을 만들되 조사 결과를 거래하지 못하게 한다.

## 2. 조직 원칙

### 2.1 Editorial independence

- 편집팀은 sales/fundraising의 사건 공개·우선순위 요청을 거부할 권한과 의무가 있다.
- 계약서에는 유료 고객이 조사 면제, 선공개, 비공개, 순위 조정을 요구할 수 없다고 명시한다.
- 주요 정책 변경은 change log와 effective date를 공개한다.

### 2.2 Separation of duties

| 기능 | 할 수 있는 일 | 할 수 없는 일 |
|---|---|---|
| Data/Engineering | source·rule·platform 운영 | 특정 사건 공개 승인 |
| Editorial | 사건 조사·문장·승인 | billing/고객 할인 결정 |
| Legal | 위험 검토·조건 제시 | 근거 없는 삭제 지시 |
| Sales | API/워크스페이스 판매 | 사건 우선순위·임계값 변경 |
| Fundraising | 후원 유치·공개 | 후원자 사건 은폐 |
| Board/Oversight | 정책·감사·이해상충 | 일상 사건을 비공개로 개입 |

소규모 초기 팀에서 한 사람이 여러 역할을 맡더라도 시스템 권한과 승인 기록은 역할별로 분리한다. 자기 작성 사건의 단독 최종 승인은 금지한다.

## 3. 단계별 운영 구조

### Stage 0 — Founder-funded research prototype

- 실제 의혹 공개 금지
- synthetic/방법론 연구만
- 결제 기능 없음
- 법률·보안 외부 자문 목록 구축

### Stage 1 — Public-benefit pilot

- 별도 운영 법인 또는 명확한 사업 단위
- 편집 정책, 개인정보처리방침, 이용약관, 정정 창구 공개
- 개인 후원과 제한된 재단 지원
- 고위험 공개 전 외부 법률 검토

### Stage 2 — Membership and data products

- 시민 회원, 고급 알림, 연구 API, newsroom workspace
- 무료 public facts/evidence는 paywall 뒤로 이동 금지
- 유료 기능은 편의·속도·분석 도구에 한정

### Stage 3 — Institutional audit SaaS

- 기관 내부 private detection workspace 가능
- public editorial pipeline과 tenant data/roles/DB를 분리
- SaaS 고객 계약이 public case suppression을 만들지 못함
- public data에서 이미 발견된 사건을 고객에게 먼저 은폐해주는 조항 금지

### Stage 4 — 필요 시 법인 분리

수익 규모와 이해상충이 커지면 공익 편집 조직과 영리 분석 회사를 분리할 수 있다. 분리 전 shared data, brand, staffing, funding, conflict, publication timing을 다루는 독립성 협약이 필요하다.

## 4. 허용 수익원

### 4.1 개인 회원·후원

- 월/연 정기 후원
- 혜택: 알림 customization, briefing, community event, early methodology preview
- 금지 혜택: 특정 대상 조사 요청 보장, 사건 삭제, 미공개 내부정보

### 4.2 재단·연구 지원

- 탐사보도, civic tech, open data, anti-corruption, 데이터 품질 연구 지원
- grant purpose와 amount band 공개
- deliverable이 편집 결론을 미리 지정하면 거절

### 4.3 데이터 API/대량 export

- 무료 tier: 공개 case/methodology의 합리적 rate
- 유료 tier: 높은 quota, bulk export, webhook, historical snapshots, SLA
- 개인식별·비공개 editorial 데이터는 판매하지 않음

### 4.4 Newsroom/research workspace

- saved query, cohort builder, team annotation, provenance export
- public 전 investigation lead는 엄격한 계약과 embargo 정책 필요
- 고객이 자체 결론을 내릴 때 구린네 로고/판정으로 오인시키지 않음

### 4.5 Internal audit SaaS

- 기관 자신의 계약 이상 패턴 사전 점검
- 결과는 해당 tenant에 비공개
- public editorial rule과 동일할 필요는 없지만 변경 내역과 편향 위험을 기록
- public platform의 조사 대상 면제와 연결 금지

### 4.6 교육·컨설팅

- 데이터 품질, 조달 분석, 투명성 체계 교육
- 특정 공개 사건의 favorable opinion 판매 금지

## 5. 금지 수익원과 거래

- pay-to-remove, pay-to-correct, pay-to-delay
- “부패 점수 개선” 컨설팅
- 조사 대상 업체의 사건 상세 페이지 native ad
- 특정 정당·후보를 위한 비공개 상대 공격 데이터
- 개인정보·제보자 정보 판매
- 사전에 결론을 정한 sponsored investigation
- affiliate link가 가격 비교 기준을 왜곡하는 구조
- 위법하거나 약관을 우회해 얻은 데이터 판매

## 6. 광고 정책

초기에는 광고를 도입하지 않는다. 향후 광고가 필요하면 별도 ADR과 다음 최소 조건이 필요하다.

- 사건 본문과 명확히 분리
- 조사 대상·공공조달 사업자 광고 제한
- 행동 추적과 정치 광고 금지
- 광고주가 editorial data에 접근 불가
- 광고 차단 여부가 정보 접근을 제한하지 않음

## 7. 후원자·고객 투명성

분기별 public disclosure에 포함한다.

- 단일 후원자/고객의 연간 수익 비중 band
- 일정 금액 이상 기관명과 목적(법적 허용 범위)
- 정부·정당·조달업체 관련 funding 여부
- 이해상충이 있는 case 목록과 대응
- editorial 정책 위반 요청 건수와 처리 결과(개인정보 제외)

초기 내부 경보 임계값:

- 단일 출처가 예상 연매출의 15%를 넘으면 oversight review
- 25%를 넘으면 board 승인과 public disclosure 강화
- 조사 대상 또는 그 관계자가 5%를 넘으면 해당 case independent review

이 비율은 자동 불법 기준이 아니라 거버넌스 guardrail이다.

## 8. 조사 우선순위의 허용 입력

허용:

- 공공자금 규모
- 데이터 품질과 evidence coverage
- 시민 영향·안전 영향
- pattern novelty와 반복성
- 법정/공식 deadline
- 시간 경과로 자료 소실 가능성
- 여러 독립 source에서 같은 signal

금지:

- 고객·후원자 여부
- 광고 가치
- 대상의 정치 성향
- 소셜미디어 클릭 가능성만
- 창업자의 개인적 호불호
- 소송 위협만을 이유로 한 비공개

## 9. 공개 비용과 법률 방어 기금

매출의 일정 비율을 다음에 우선 배정한다.

- 데이터 라이선스·보존
- 외부 법률 검토와 분쟁 대응
- 보안 감사와 incident response
- 정정·소명 운영 인력
- 독립 방법론 검토

파일럿 권장 reserve 정책:

- 연간 운영비의 최소 3개월 현금성 reserve 목표
- 별도 legal/security contingency line
- 고위험 사건을 게시할 예산이 없으면 자동 게시하지 않고 보류

## 10. 가격 정책 원칙

- public case와 근거는 무료
- 가격은 사용량·협업·SLA·연산량에 기반
- 고객의 기관 규모나 사건 민감도에 따른 은폐 가격 차등 금지
- nonprofit/언론/연구 discount는 공개 기준
- API 결과에는 source license/attribution metadata 포함

## 11. Governance controls in product

시스템은 원칙을 문서만이 아니라 권한으로 강제한다.

- billing tables와 editorial DB schema 분리
- detection job에는 customer/funder ID field 금지
- admin action audit
- conflict-of-interest flag와 reviewer recusal
- 자기승인 금지
- high-risk publication dual approval
- policy change diff와 effective date
- public funding disclosure page revision history

## 12. 핵심 KPI

수익 KPI:

- recurring revenue, gross margin, customer concentration, runway

신뢰 KPI:

- correction rate와 severity
- response 반영률
- citation/provenance completeness
- public methodology usage
- independent reuse
- source coverage와 freshness

잘못된 KPI:

- “비리 적발 수” 극대화
- 자극적 headline CTR
- correction 숨기기로 유지한 publication count

## 13. 의사결정 절차

수익모델이 편집 정책과 충돌할 가능성이 있으면 다음 순서를 따른다.

1. conflict description
2. affected users/cases
3. 가능한 대안
4. editorial/legal/security 의견
5. 공개 가능한 decision memo
6. board/oversight 승인
7. implementation ADR와 audit control
8. 90일 후 영향 검토

수익 부족은 공개 안전 게이트를 완화하는 사유가 아니다.

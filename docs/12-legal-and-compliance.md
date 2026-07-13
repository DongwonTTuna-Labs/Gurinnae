# 12. 법률·컴플라이언스 설계 기준

## 1. 중요 고지

이 문서는 기술·제품의 fail-closed 요구사항이며 대한민국 변호사의 법률 자문이 아니다. 실제 서비스 공개 전, 그리고 고위험 사건마다 현행 법령·판례·사실관계에 대한 독립 법률 검토가 필요하다.

Research snapshot: 2026-07-10. 법령은 개정될 수 있으므로 effective date를 다시 확인한다.

## 2. 관련 법률 영역

- 공공데이터의 제공 및 이용 활성화에 관한 법률
- 공공기관의 정보공개에 관한 법률
- 국가·지방자치단체 계약 관련 법령
- 개인정보 보호법
- 저작권·공공누리 및 source별 이용조건
- 형법상 명예훼손·모욕 및 민사상 불법행위
- 정보통신서비스 관련 게시물·분쟁 절차
- 공익신고자 보호와 부패신고 관련 법령
- 국가안보·군사기밀·수사/감사 비공개 영역
- 선거 시기 정치적 표현·선거법 영역

서비스가 언론으로 분류되는지, 기사/게시물 책임, 정정보도 제도 적용 등은 운영 형태에 따라 별도 검토한다.

## 3. 법적 설계 원칙

### 3.1 Public does not mean unrestricted

공식 페이지에 보인 정보라도:

- 재배포 license가 제한될 수 있음
- 개인 연락처와 결합해 검색 가능성을 키우면 추가 침해 가능
- 사실 적시도 명예훼손 위험이 존재
- 삭제/정정된 원문을 계속 mirror하는 데 위험
- 안보 정보를 aggregation하면 harm가 커질 수 있음

따라서 source 접근 권리, 저장 권리, 재배포 권리, 공개 표현 책임을 분리해 검토한다.

### 3.2 Purpose limitation and minimization

업체 식별·소명 목적에 필요한 정보만. 대표자명, 담당자 연락처, 상세 주소를 “나중에 쓸 수 있다”는 이유로 public index에 저장하지 않는다.

### 3.3 Verification and public interest

명예를 저하시킬 수 있는 사실은 공익성, 진실성 또는 진실하다고 믿을 상당한 이유, 검증 절차, 표현 방식이 중요할 수 있으므로:

- primary evidence
- independent verification
- right of reply
- uncertainty and context
- no sensational wording
- legal review

를 강제한다.

## 4. 법률 위험 분류 flags

```text
NAMED_INDIVIDUAL
SOLE_PROPRIETOR_PERSONAL_IDENTITY
CRIMINAL_IMPLICATION
COLLUSION_OR_BRIBERY_LANGUAGE
ELECTION_OR_POLITICAL_ACTOR
NATIONAL_SECURITY
ONGOING_INVESTIGATION
MINOR_OR_VULNERABLE_PERSON
MEDICAL_OR_SENSITIVE_PERSONAL_DATA
CONFIDENTIAL_RESPONSE
SOURCE_LICENSE_UNCLEAR
UPSTREAM_REMOVAL_REQUEST
COURT_ORDER_OR_INJUNCTION
WHISTLEBLOWER_RISK
```

하나라도 있으면 standard gate 외 추가 legal decision이 필요하다. `WHISTLEBLOWER_RISK`, 비공개 안보, 민감정보는 public prohibited가 기본값.

## 5. 개인정보

### Data inventory

각 field에:

- data subject
- source
- purpose
- lawful basis/legal review
- internal/public classification
- retention
- processors/model providers
- deletion/redaction path

를 기록한다.

### Public-source PII

공개 문서의 담당자 이름·전화·이메일은 계약 사실을 설명하는 데 대개 필요하지 않다. parser 단계에서 분류하고 public projection에서 제거한다.

### Supplier identity

법인명/상호는 계약 party로 필요할 수 있으나 개인사업자는 사람의 명예와 직접 연결될 수 있어 MEDIUM/HIGH risk. 사업자번호 전체는 public 금지.

### Rights request

access/correction/deletion/restriction 요청 접수, identity verification, legal hold, response SLA를 운영한다. 공개 기록의 정정과 개인정보 삭제는 서로 다른 절차일 수 있다.

### Data breach

개인정보 사고는 security incident와 법정 신고/통지 의무 검토를 동시에 시작한다.

## 6. 명예·평판 위험

### 표현 분리

- Fact: 공식 계약과 수치
- Analysis: versioned metric
- Interpretation: 설명 필요
- Legal status: 공식 source가 명시한 정확한 단계

“의혹”, 질문형 제목, AI 점수로 사실 적시 책임을 회피할 수 있다고 가정하지 않는다.

### 대상 특정

이니셜·주소·계약 정보 조합만으로도 대상이 특정될 수 있다. redaction은 이름 삭제만이 아니다.

### 회사/기관

법인·단체도 신용과 평판 피해가 생길 수 있다. 업체 실명 공개는 identity와 comparison 검증 후.

## 7. Right of reply and correction

법적 면책을 위한 형식적 절차가 아니라 정확성을 높이는 핵심.

- exact claims and reasonable deadline
- official/verified contact
- meaningful response visibility
- material response after publication도 신속히 반영
- correction request는 보복 없이 추적
- threatening language와 factual correction을 분리

## 8. 공공데이터·저작권·license

Source registry에:

- 이용허락범위
- attribution
- 상업적 이용/변경 제한
- raw document 재배포
- API response caching
- logo/trademark
- attachment 별도 license

를 기록한다.

가능한 public 방식:

1. source link + structured facts + checksum
2. 허용된 짧은 excerpt
3. redistribution 허용 파일 mirror
4. 금지/불명확하면 private preservation only

공공누리 유형이 파일/페이지별로 다를 수 있으므로 portal 전체를 하나로 가정하지 않는다.

## 9. 정보공개법과 비공개 정보

정보공개 체계에는 공개 원칙과 함께 법률상 비공개 대상이 존재한다. 구린네는 비공개 결정을 우회하거나 leak를 수집하도록 설계하지 않는다.

- 공개 API/페이지에서 정상 접근한 정보만
- 인증/권한 우회 금지
- 우연히 노출된 secret/개인정보는 즉시 quarantine하고 재배포 금지
- 정보공개 청구 자동화는 별도 legal process

## 10. 계약법 threshold와 위법 표현

수의계약·입찰 예외는 계약 유형, 금액, 목적, 시점, 긴급성 등 복잡하다. 따라서:

- legal threshold를 code에 상수로 박지 않음
- `JurisdictionPolicyVersion` + effective date
- rule은 “threshold 근처 반복 패턴” lead
- 위법 여부는 공식 조문·사실과 legal review 없이는 표현 금지

## 11. 군사·안보

- 공개 조달이라도 exact location, quantity, timing, capability를 aggregation하면 위험 가능
- 군사 품목 category는 high-risk filter
- operational near-real-time views 금지
- source의 redaction을 추정 복원하지 않음
- 국가안보 비공개 대상 가능성 있으면 legal/security review
- 공익적 예산 분석과 실제 작전 정보 노출을 구분

## 12. 공익·부패 신고

공식 기관에 자료를 전달할 때:

- 신고 요건과 channel 확인
- 신고자/협조자 보호
- 비실명 대리신고 등 공식 제도 안내 가능
- 자동 신고/대리 자처 금지
- 전달 package와 consent/legal basis
- case publication과 referral 독립 결정

## 13. 선거·정치

선거 전후 정치인·정당 관련 case는 high-risk.

- 모든 대상에 동일 방법론
- release timing과 공익/정확성 review
- paid political targeting 금지
- 개인 정치 성향을 detection input으로 사용 금지
- 선거법 전문 검토 없이는 candidate score/endorsement 기능 금지

## 14. 보존·legal hold

소송·공식 요청·사고가 예상되면 relevant records에 legal hold. 일반 retention deletion을 중단하되 범위와 승인·해제 기록.

법 집행기관 요청:

- 요청의 법적 유효성 검토
- 최소 범위
- 제보자/사용자 통지 가능성 검토
- request/response audit
- 투명성 보고서 집계 가능

## 15. Takedown/complaint process

Public channel:

- factual correction
- privacy
- copyright/license
- security
- legal notice
- response/additional context

Intake는 자동 삭제를 하지 않는다. 긴급 privacy/security는 임시 제한 가능. 모든 요청에 case ID, receipt, triage, decision, appeal/contact를 제공한다.

## 16. Legal review packet

고위험 사건 검토자는 다음을 받는다.

- current exact draft/content hash
- claim-evidence matrix
- source documents and provenance
- calculation reproducibility bundle
- identity verification
- counter-hypotheses
- response request/submission
- risk flags
- proposed wording and public interest rationale
- redaction/license status
- previous corrections/related cases

초안이 바뀌면 review를 갱신한다.

## 17. Launch prerequisites

- 운영 법인/책임자 확정
- 이용약관·개인정보처리방침
- correction/takedown contact
- source별 license matrix
- DPIA/data map
- external Korean counsel review
- media liability/cyber insurance 검토
- incident/law enforcement request procedure
- public editorial policy

## 18. 공식 연구 출처

정확한 URL과 기준일은 `docs/research-sources.md`. 특히 현행 version을 activation/publication 시 재검증한다.

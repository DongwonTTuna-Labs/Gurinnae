# 29. 사용자, Jobs-to-be-Done과 핵심 여정

## 1. 목적

페르소나는 인구통계 장식이 아니라 제품 결정에 필요한 행동·지식·위험 차이를 표현한다. 코덱스는 “일반 사용자”라는 추상 사용자만 가정해서는 안 된다.

## 2. 외부 사용자

### 2.1 시민 독자 — 지민

상황:

- 특정 지자체 계약이 SNS에서 논란이라는 말을 들었다.
- 공공조달 전문가는 아니며 가격 단위와 계약 구조에 익숙하지 않다.
- 결론을 빠르게 알고 싶지만 과장된 정보는 피하고 싶다.

JTBD:

> “논란이 된 계약에서 실제로 확인된 사실과 아직 모르는 사실을 구분해, 다른 사람에게 책임 있게 설명하고 싶다.”

필요:

- 쉬운 상태 설명
- 한 문단 요약
- 가장 중요한 미확인 항목
- 시각적 비교와 표
- 기관·업체 소명
- 원문으로 내려갈 수 있는 경로

실패:

- 가격 배수만 보고 비리로 오해
- 오래된 revision을 최신으로 오인
- source가 포함하지 않는 기간을 “계약 없음”으로 해석

### 2.2 탐사 기자 — 서윤

JTBD:

> “공개 사건의 원문·계산·변경 이력을 빠르게 검증하고, 기사에서 안정적으로 인용하고 싶다.”

필요:

- stable URL과 revision
- evidence locator
- 다운로드와 재현 정보
- 데이터 coverage
- 소명 제출 시각과 문구
- correction feed

실패:

- 동적으로 바뀌는 숫자를 과거 기사에 인용
- public page와 internal signal을 혼동
- 비공개 원본의 존재만으로 주장을 강화

### 2.3 연구자·시민단체 분석가 — 현우

JTBD:

> “여러 기관의 계약 패턴을 재현 가능한 데이터로 분석하되, 기관 순위가 데이터 범위 차이를 왜곡하지 않게 하고 싶다.”

필요:

- methodology/rule version
- source·기간·누락 범위
- machine-readable download
- 기관·업체 identity history
- correction/retraction dataset
- API rate-limit과 license

### 2.4 기관·업체 소명 담당자 — 민정

JTBD:

> “우리 조직에 제기된 구체적인 질문과 근거를 확인하고, 승인된 답변과 자료를 안전하게 제출해 기록을 남기고 싶다.”

필요:

- 요청자·대상·기한·질문 목록
- 제출 범위와 공개 동의 설명
- draft 저장
- 파일 검증·삭제
- 최종 확인 화면
- 접수 영수증
- 기한 연장 요청

위험:

- token이 제3자에게 공유됨
- 내부 영업비밀·개인정보가 과다 제출됨
- 임시 저장이 제출로 오인됨
- 제출 후 수정 가능 여부가 불명확함

### 2.5 정정 요청자 — 당사자 또는 시민

JTBD:

> “어떤 문장이나 수치가 왜 잘못됐는지 근거와 함께 지정해, 처리 상태를 확인하고 싶다.”

필요:

- 정확한 URL/revision/claim 선택
- 오류 유형
- 근거 첨부
- 개인정보 공개 범위
- 영수증과 reference
- 긴급 피해 채널과 일반 정정의 구분

## 3. 내부 사용자

### 3.1 Triage 담당자

JTBD:

> “새 signal이 데이터 오류인지 조사 가치가 있는지 짧은 시간 안에 판정하고, 판정 근거를 남기고 싶다.”

필요:

- 결정적 계산과 입력 필드
- blocker 상태
- 비교군 분포
- duplicate/related signal
- parser/source 품질
- AI 제안은 보조 섹션
- 한정된 결정 option

### 3.2 조사자

JTBD:

> “여러 signal을 하나의 사건 가설로 구성하고, 지지·반대 근거와 미확인 항목을 체계적으로 해소하고 싶다.”

필요:

- 사건 task rail
- 가설별 evidence matrix
- source locator
- 비교 cohort
- research task
- 소명 요청
- agent run provenance
- conflict/version handling

### 3.3 편집자

JTBD:

> “공개 문장의 정확성·명확성·공정성을 검토하고, claim마다 충분한 근거와 한계가 있는지 확인하고 싶다.”

필요:

- claim-evidence mapping
- prohibited language
- response inclusion
- timeline
- publication preview
- current snapshot hash
- 변경 diff

### 3.4 법률 검토자

JTBD:

> “사실·의견·추론을 구분하고 명예훼손·개인정보·영업비밀 위험을 검토한 뒤 조건부 결정을 남기고 싶다.”

필요:

- exact publication snapshot
- evidence access classification
- 개인 식별정보
- 소명 상태
- 법률 쟁점 checklist
- hold/review date
- 독립적 승인 기록

### 3.5 게시 승인자

JTBD:

> “모든 gate가 최신 snapshot에서 충족됐는지 확인하고, 게시 또는 반려의 책임 있는 결정을 내리고 싶다.”

필요:

- readiness summary
- unresolved blockers
- reviewer independence
- diff since review
- scheduled publication
- rollback/incident path
- the command’s declared assurance level

### 3.6 데이터 운영자

JTBD:

> “source 수집이 정상인지, schema가 바뀌었는지, backfill이 중복 없이 실행되는지 확인하고 싶다.”

필요:

- source health
- checkpoint
- run diagnostics
- quarantine
- schema diff
- replay scope
- downstream impact

### 3.7 규칙 분석가

JTBD:

> “탐지 규칙의 precision·오탐과 cohort 민감도를 평가하고, shadow 실행 후 안전하게 활성화하고 싶다.”

필요:

- version diff
- gold/false-positive eval
- threshold simulation
- affected signal estimate
- rollback version
- approval trail

### 3.8 운영·보안 관리자

JTBD:

> “작업 적체·비용·공급자 장애·보안 사고를 감지하고 최소 권한으로 대응하고 싶다.”

필요:

- job/DLQ
- provider state
- spend envelope
- kill switch
- audit explorer
- role changes
- incident runbook

## 4. 핵심 외부 여정

### J-01. 논란을 확인하는 시민

1. 검색 또는 공유 URL로 사건 상세 진입
2. 상단에서 현재 상태와 최신 revision 확인
3. “확인된 사실 / 중요한 미확인 / 당사자 소명” 읽기
4. 비교 차트와 비교조건 확인
5. evidence drawer에서 원문 locator 확인
6. 관련 계약 또는 방법론으로 이동
7. 필요하면 업데이트 알림 구독 또는 정정 요청

성공 조건:

- 사용자가 위법 확정 여부를 정확히 말할 수 있다.
- 데이터 한계 한 가지 이상을 식별한다.
- 원문에 도달할 수 있다.

### J-02. 기자의 인용과 재현

1. 사건 최신 revision과 publication timestamp 확인
2. claim별 evidence와 source retrieval timestamp 확인
3. 재현 페이지에서 rule version·input digest·cohort 다운로드
4. 당사자 소명과 correction timeline 확인
5. revision URL을 기사에 인용
6. 사건 업데이트 구독

### J-03. 기관·업체의 소명

1. 요청 이메일의 안전 안내 확인
2. response portal token 열기
3. 대상 사건·질문·기한·공개 범위 확인
4. 조직 내 답변 준비 후 draft 입력
5. 첨부파일 upload·검사 상태 확인
6. 공개 동의 범위 선택
7. check answers 화면에서 최종 검토
8. 제출 후 영수증 저장
9. 내부 담당자가 추가 질문하면 새로운 request로 응답

### J-04. 정정 요청

1. 사건 또는 correction request 페이지에서 시작
2. 대상 URL/revision/claim 선택
3. 오류 유형과 설명 입력
4. 근거 링크·파일 제출
5. 개인정보·공개 동의 확인
6. 영수증/reference 수신
7. 결과가 correction log에 반영되면 알림

## 5. 핵심 내부 여정

### J-05. Signal triage

1. queue에서 source freshness·rule·blocker로 필터
2. signal detail에서 원본 입력과 계산 확인
3. 비교군 분포와 제외 사유 검토
4. duplicate/related signal 확인
5. AI suggestion은 마지막에 참고
6. `DISMISS`, `NEEDS_DATA`, `PROMOTE_TO_CASE`, `LINK_TO_CASE` 중 선택
7. reason code와 note 제출
8. optimistic concurrency 충돌 시 최신 상태와 diff 검토

### J-06. 조사 사건 구성

1. 승격된 signal로 사건 생성
2. 조사 질문과 가설 정의
3. 지지·반대 evidence 연결
4. 알려진 사실·미확인 항목 관리
5. entity identity와 단위·bundle 검증
6. 필요시 research agent 실행
7. 소명 요청 초안 작성·승인·발송
8. 응답을 evidence와 claim에 연결
9. editorial readiness로 전환

### J-07. 독립 검토와 게시

1. 고정된 review snapshot 생성
2. 독립 reviewer가 claim·evidence·response·language 검토
3. 조건부 수정 또는 반려
4. 수정 후 새 snapshot 생성; 오래된 승인 무효화
5. 게시 승인자가 gate와 diff 확인
6. STEP_UP authorization 후 게시 command
7. public projection 생성 및 smoke 확인
8. 영수증과 audit event 기록

### J-08. 정정·철회

1. 내부 탐지 또는 외부 요청 접수
2. 긴급 피해/법률 hold 여부 분류
3. 원문·claim·영향 revision 확인
4. 수정 문구와 이유 작성
5. 독립 검토
6. correction 또는 retraction revision 게시
7. 관련 페이지·feed·구독자 알림
8. 원인 분석과 규칙/프로세스 개선 기록

### J-09. Source schema drift

1. parser mismatch 경고
2. 새 payload quarantine
3. old/new schema diff 확인
4. 영향 field와 downstream rule 파악
5. parser fixture·migration 업데이트
6. shadow parse
7. 재처리 scope 승인
8. backfill/replay
9. source health 회복과 public freshness 갱신

## 6. 서비스 블루프린트 예시: 게시

| 단계 | 사용자 화면 | SvelteKit | API | 도메인/DB | 비동기 |
|---|---|---|---|---|---|
| readiness | gate checklist | server load | control query | snapshot/read model | 없음 |
| review | diff·evidence | server action | review command | immutable decision | outbox |
| publish confirm | 영향·reauth | BFF | publish command | expected_version/gates | projection job |
| receipt | publication ID | SSR | receipt query | audit/outbox | projector |
| public verify | 공개 case | public SSR | public read | public schema | cache purge |
| incident | rollback notice | operations UI | correction/retract | new revision | notification |

## 7. Journey별 연구 과제

구현 전에 최소한 다음 task를 prototype로 검증한다.

- 시민이 30초 안에 현재 상태와 중요한 미확인을 설명할 수 있는가?
- 기자가 claim 하나의 원문 locator를 2분 안에 찾는가?
- triager가 단위 불일치 signal을 오탐으로 정확히 분류하는가?
- 조사자가 반대 evidence를 누락하지 않고 연결하는가?
- reviewer가 오래된 snapshot 승인을 알아차리는가?
- response party가 draft와 submit을 혼동하지 않는가?
- 데이터 운영자가 schema drift 영향 범위를 정확히 파악하는가?
- keyboard-only 사용자가 핵심 행동을 완료하는가?

## 8. 사용자 연구 기록

각 연구 session은 다음을 남긴다.

- 연구 목적과 가설
- 참가자 역할과 숙련도
- 사용한 prototype/spec version
- task와 성공 기준
- 관찰 사실과 해석 분리
- severity
- 결정과 owner
- 반영된 screen/component ID
- 재검증 필요 여부

사용자 연구에서 나온 단일 의견을 곧바로 requirement로 승격하지 않는다. 반복되는 문제, 법적 위험, task 실패를 우선한다.

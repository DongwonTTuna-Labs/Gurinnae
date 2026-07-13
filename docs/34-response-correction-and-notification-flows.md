# 34. 소명·정정·알림 제품 흐름

## 1. 목적

소명과 정정은 부가 기능이 아니라 구린네의 공정성과 신뢰를 구성하는 핵심 기능이다. 제출자의 입장에서는 안전하고 예측 가능해야 하며, 내부 조사자에게는 검증 가능한 기록이어야 한다.

## 2. 소명 요청 생성

내부 조사자는 다음을 입력한다.

- 대상 조직과 확인된 contact
- 사건과 관련 claim
- 질문 목록
- 요청 근거 또는 인용 자료
- 응답 기한과 timezone
- 공개 예정 범위
- 제출 가능한 파일 형식·용량
- 개인정보·영업비밀 안내
- 담당자 연락처
- 연장 정책

발송 전 gate:

- contact source와 최신성
- 질문이 중립적이고 구체적인가
- 미확정 내용을 범죄로 단정하지 않는가
- 불필요한 개인정보가 포함되지 않았는가
- 이미 열린 요청과 중복되지 않는가
- 법률 review가 필요한가
- request snapshot이 고정됐는가

## 3. 요청 전달

이메일에는 다음만 포함한다.

- 구린네의 정체성과 연락처
- 대상 사건의 공개 또는 안전한 설명
- 응답 기한
- response portal 링크
- phishing 확인 방법
- 링크를 전달하지 말라는 안내
- 이메일로 민감자료를 회신하지 말라는 안내

전체 내부 evidence나 token scope를 이메일 본문에 노출하지 않는다.

## 4. Response Portal 단계

### 4.1 Landing / verification

- organization/request identity
- 만료와 scope
- 보안 안내
- 필요 시 이메일 OTP 또는 추가 검증
- 개인정보·쿠키 최소 안내

### 4.2 Request overview

- 질문 목록
- 관련 공개 claim/evidence
- due date
- expected processing
- public use options
- 담당자
- extension action

### 4.3 Answer editor

질문별 구조화 답변과 전체 입장을 구분한다.

- question
- answer
- supporting reference
- confidential note 분리
- public use consent
- character limit
- save state

confidential이라고 표시해도 법적 보장 범위를 과장하지 않으며 처리 정책을 링크한다.

### 4.4 Attachments

- 허용 파일 형식·크기
- upload progress
- malware scan 상태
- filename redaction 안내
- 설명과 문서 날짜
- public use classification
- remove/replace

검사 완료 전 submit 금지. 압축파일·매크로·실행파일은 기본 금지 또는 quarantine.

### 4.5 Check answers

모든 답변·파일·동의·연락처를 한 화면에서 검토한다.

- `Change` 링크
- 제출 후 변경 정책
- 정확성 확인
- 권한 확인
- 개인정보 경고
- explicit submit

### 4.6 Receipt

- receipt ID
- submitted time/timezone
- request ID
- 제출 항목 요약
- download 가능한 receipt
- 다음 절차
- 수정·추가 자료 방법
- 담당 연락처

내부 case 상태나 publish date를 약속하지 않는다.

## 5. Draft 정책

- token 범위의 encrypted server draft
- 저장 시각 표시
- draft retention
- 여러 기기 충돌 안내
- 브라우저 localStorage에 답변 원문 저장 금지
- expired request의 draft 처리
- submit 후 immutable submission, 수정은 새 supplement

## 6. 공개 동의 모델

선택지는 명확히 구분한다.

- `FULL`: 제출 원문과 지정 첨부의 공개를 허용
- `REDACTED`: 개인정보·영업비밀 redaction 후 공개
- `SUMMARY_ONLY`: 편집 요약만 공개
- `NO_CONSENT_REVIEW_LEGAL_BASIS`: 동의하지 않으며 구린네는 별도 법적 근거를 검토

동의는 공개 여부를 자동 결정하지 않는다. 편집·법률 검토를 거친다.

## 7. 기한 연장

응답자는 다음을 제출한다.

- 요청 연장일
- 이유
- 부분 답변 가능 여부
- 연락처

내부 담당자는 승인/조정/거절하고 새 due date를 기록한다. 무응답과 승인된 연장을 구분한다.

## 8. 내부 response intake

제출 후:

1. virus/content scan
2. immutable record
3. intake task
4. organization identity 확인
5. 답변을 질문·claim과 연결
6. 사실 주장 검증
7. 공개 동의·redaction 검토
8. public excerpt 초안
9. 응답자 표현과 편집자 해석 분리
10. readiness gate 재평가

## 9. 정정 요청

### 9.1 대상 선택

가능한 시작점:

- 사건 상세의 특정 claim
- 계약/기관/업체 identity
- correction request general form

필수:

- URL
- revision
- claim/evidence ID(가능하면)
- 오류 유형
- 정확한 문제 설명
- 제안 수정
- 근거
- 연락 방법

오류 유형:

- factual error
- calculation error
- identity mismatch
- missing context
- outdated information
- privacy/personal data
- legal concern
- broken source
- accessibility
- other

### 9.2 긴급 경로

다음은 일반 queue보다 빠르게 triage한다.

- 민감 개인정보 노출
- 잘못된 실명 식별
- 명백한 문서 오연결
- 법원 명령 또는 안전 위험
- active credential/token 노출

긴급 표시가 자동 삭제를 의미하지 않는다. 임시 제한과 review를 기록한다.

### 9.3 Receipt와 tracking

public account 없이 receipt ID와 magic management link를 제공한다.

표시 가능한 상태:

- received
- triaged
- more information requested
- under review
- resolved with correction
- resolved without correction
- withdrawn

내부 메모와 법률 의견은 노출하지 않는다.

## 10. 정정 workspace

- original claim/revision
- requester statement
- supporting evidence
- impact analysis
- related pages/API/downloads
- urgency
- owner/SLA
- proposed correction
- reviewer decisions
- notification scope
- root cause

수정은 원본 overwrite가 아니라 새 publication revision이다.

## 11. 알림 시스템

### 11.1 구독 대상

- case
- agency
- supplier
- methodology/rule
- corrections
- source coverage

### 11.2 event

- publication.created
- response.added
- publication.corrected
- publication.retracted
- official.finding.added
- methodology.changed
- source.coverage.changed

### 11.3 이메일 문구

제목 예:

> [구린네] 구독 중인 사건에 기관 소명이 추가되었습니다

금지:

> 충격! 비리 의혹 폭발
> 이 기관 또 걸렸다

### 11.4 빈도와 제어

- 즉시, 일간 요약, 주간 요약
- event별 선택
- one-click unsubscribe
- magic management
- bounce/suppression
- duplicate collapse
- correction/retraction은 우선 전달

## 12. 개인정보·보안

- correction/response 본문을 일반 product analytics에 전송하지 않는다.
- 파일명, token, 이메일을 URL query analytics에서 제거한다.
- attachment는 object store quarantine과 content-type 검증.
- 내부 다운로드는 audit.
- 공개 redaction은 원본을 덮어쓰지 않고 derivative로 생성.
- retention과 deletion은 법률·증거 보존 정책에 따른다.

## 13. Acceptance

- draft와 submit의 의미가 시각·문구로 구분된다.
- token으로 다른 request를 조회할 수 없다.
- file scan 완료 전 제출할 수 없다.
- public consent가 자동 게시로 이어지지 않는다.
- 무응답을 인정으로 표현하지 않는다.
- 정정 요청이 publication을 직접 변경하지 않는다.
- correction은 새 revision과 audit를 만든다.
- notification은 latest state와 correction을 반영한다.
- unsubscribe는 로그인 없이 가능하다.

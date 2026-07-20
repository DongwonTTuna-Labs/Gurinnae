# 30. 제품 Surface와 신뢰 경계

## 1. 결정

구린네는 세 개의 독립 웹 애플리케이션과 세 개의 API 경계를 가진다.

```text
Public Web        → Public API (read only)
                  → Submission API (server-side limited writes)

Review Console    → Control API (server-side internal commands)

Response Portal   → Submission API (server-side token-scoped writes)
```

이 구조는 UX 구분만이 아니라 보안·데이터 최소화·운영 책임을 강제하는 제품 결정이다.

## 2. Public Web

### 책임

- 공개 사건·계약·기관·업체·방법론·source·정정 탐색
- 공개 데이터 다운로드와 API 문서
- 이메일 구독 시작·관리
- 정정 요청 제출
- 서비스 정책·funding·governance 공개

### 계정 정책

핵심 읽기는 계정이 필요 없다. 구독자는 전통적인 비밀번호 계정을 만들지 않는다.

- 이메일 verification link로 구독 활성화
- 관리 magic link는 짧은 수명과 단일 목적
- 이메일 주소는 공개 analytics identity와 결합하지 않음
- 기관·업체를 follow하더라도 그 자체를 비리 관심으로 해석하지 않음

### 쓰기 경계

브라우저가 Submission API credential을 직접 가지지 않는다. SvelteKit server action이 다음을 수행한다.

- CSRF·origin 검증
- rate limit/captcha 정책 적용
- payload schema validation
- submission API 호출
- token/receipt 최소 노출

## 3. Review Console

### 책임

- signal triage
- 사건 조사와 evidence 관리
- claim·response·publication 작성
- 독립 review와 승인
- source·rule·job·비용·audit 운영
- 사용자·역할 관리

### 인증

- 조직 OIDC
- MFA
- 역할 기반 권한
- `assurance_level: STEP_UP` 행동의 recent reauthentication
- 짧은 idle timeout
- device/session list
- 계정 잠금 및 offboarding

### 브라우저 경계

Control API access token은 브라우저 JavaScript에 노출하지 않는다. Review Console의 SvelteKit server가 Backend-for-Frontend 역할을 한다.

금지:

- `PUBLIC_*` 환경변수에 control URL 또는 token
- generated control client를 `+page.svelte`에서 import
- localStorage에 access/refresh token 저장
- public web bundle과 코드 분할 chunk에 internal model 포함

## 4. Response Portal

### 책임

- 단일 response request 표시
- 질문별 답변과 첨부
- draft
- 공개 동의 범위
- 최종 검토와 제출
- 기한 연장 요청
- receipt

### 격리

Response Portal은 Public Web과 별도 origin을 권장한다.

```text
www.gurine.example        Public Web
review.gurine.example     Review Console
respond.gurine.example    Response Portal
```

최소 요구:

- 별도 session cookie와 이름
- `Referrer-Policy: no-referrer`
- token이 URL에서 다른 origin으로 전송되지 않도록 외부 링크 제한
- 엄격한 CSP
- third-party analytics 없음
- upload content 별도 quarantine
- search indexing 차단
- error monitoring에서 token·본문·파일명 redaction
- 한 request의 권한으로 다른 request 탐색 불가

### 인증 모델

response token은 내부 user role이 아니다.

- 충분한 entropy
- hash 저장
- 만료
- scope: request ID + allowed action
- 최초 접속 또는 제출 시 추가 verification 선택 가능
- 제출 후 token rotation/소멸
- 기한 연장은 별도 command
- brute-force rate limit

## 5. Submission API

### 도입 이유

기존 v2.1의 response endpoint가 내부 `control-api` 계약에 섞여 있었다. 이는 외부 token 요청과 내부 OIDC/RBAC command를 같은 trust zone으로 취급하는 구조적 오류다. v3에서는 다음을 Submission API로 분리한다.

- response request 조회
- response draft 저장
- attachment upload
- response 제출
- extension request
- public correction request
- subscription verify/manage
- contact form(도입 시)

### 데이터베이스 역할

`gurine_submission_api`는 최소 권한만 가진다.

허용:

- 외부 submission 전용 schema의 token·draft·receipt 접근
- 검증된 command를 outbox에 기록
- 공개 가능한 request projection 읽기

금지:

- 내부 사건 전체 조회
- editorial memo 조회
- publication 직접 변경
- role/approval 변경
- raw source 조회
- ops/audit 광범위 조회

### 내부 전달

Submission API의 외부 입력은 곧바로 사건 상태를 변경하지 않는다.

```text
External submission
→ virus/content scan
→ schema and token validation
→ immutable submission record
→ outbox event
→ internal intake queue
→ human review
→ evidence/response 연결
```

## 6. API client 경계

| Client | 사용 앱 | 위치 | 브라우저 import |
|---|---|---|---|
| `api-client-public` | Public Web, 필요 시 Review Console read link | server 또는 안전한 public request | 허용 가능 |
| `api-client-control` | Review Console | server-only | 금지 |
| `api-client-submission` | Public Web, Response Portal | server-only | 금지 |

각 client는 별도 OpenAPI JSON에서 생성한다. combined client를 만들지 않는다.

## 7. 데이터 분류와 화면 노출

| 분류 | Public Web | Review Console | Response Portal |
|---|---|---|---|
| 공개 publication | 읽기 | 읽기/preview | 요청 맥락에 필요한 일부 |
| raw source | sanitized/허용 범위 | 권한별 | 요청에 인용된 일부 |
| internal hypothesis | 금지 | 허용 | 금지 |
| editor note | 금지 | 허용 | 금지 |
| response draft | 금지 | 권한별 | 해당 token만 |
| submitted response | 승인된 공개본 | 원본/검토본 | 제출자 receipt |
| personal data | 최소·마스킹 | 필요권한 | 본인 제출 범위 |
| audit event | 공개 correction 일부 | 권한별 전체 | receipt event만 |

## 8. Surface 간 이동

### Public → Response

일반 사용자가 response portal을 발견하는 메뉴는 없다. 당사자는 전달받은 request link로 접근한다. 공개 사건의 “기관·업체 소명” 섹션은 제출된 공개본만 보여준다.

### Public → Review

직원 로그인 링크는 footer의 작은 운영 링크 또는 별도 URL로 제공할 수 있으나 public session과 SSO session을 결합하지 않는다.

### Review → Public

- public preview는 실제 public renderer와 동일 component contract를 사용한다.
- 내부 화면에서 공개 URL을 새 탭으로 열 때 referrer 정책을 고려한다.
- 미공개 case ID를 public URL로 추측 생성하지 않는다.

### Review → Response

조사자는 response request를 생성하고 발송 상태를 확인한다. portal token 자체는 다시 표시하지 않고 revoke·resend와 audit만 제공한다.

## 9. 캐시와 freshness

- Public API/SSR은 publication revision 기준으로 cache할 수 있다.
- correction/retraction은 cache purge 우선순위가 가장 높다.
- Control API response는 shared cache 금지.
- Response Portal은 `no-store`.
- 공개 목록의 최신성은 source freshness와 publication freshness를 별도로 표시한다.
- public page가 stale projection을 보이면 마지막 정상 projection version을 표시하고 내부 draft를 노출하지 않는다.

## 10. Telemetry 경계

Public Web:

- 개인정보를 최소화한 product analytics 허용
- 사건 관심을 개인 프로필로 장기 결합하지 않음
- 원문 locator·검색어는 민감 정보 검토 후 수집

Review Console:

- operational audit와 product analytics 분리
- 모든 command는 audit
- mouse heatmap/세션 녹화 기본 금지
- 조사 내용이 외부 analytics provider로 전송되지 않음

Response Portal:

- third-party analytics 금지
- 보안·성능 최소 telemetry만 self-hosted 또는 redacted
- token, 답변 본문, 파일명, organization identity 로그 금지

## 11. 위협과 완화

| 위협 | 경계 |
|---|---|
| response token이 internal API 권한으로 확대 | Submission API 독립, token-scoped authorization |
| public bundle에 내부 DTO 포함 | 별도 client/package, import lint |
| correction request가 자동 게시 상태를 변경 | intake event + human review |
| public cache에 response draft 저장 | no-store, 별도 origin/schema |
| internal search가 public endpoint로 노출 | 별도 route tree와 DB role |
| third-party script가 token 유출 | response portal CSP/referrer/analytics 금지 |
| 직원이 public preview를 최종본으로 오인 | snapshot hash·DRAFT watermark |
| 계정 해지 후 role 잔존 | OIDC deprovision + session revoke + audit |

## 12. 구현 fitness rule

- `public-web`은 control client import 금지
- `review-console`은 submission token을 처리하지 않음
- `response-portal`은 control client import 금지
- `submission-api`는 publication state write repository에 의존 금지
- public/control/submission OpenAPI operationId namespace 분리
- 모든 submission endpoint에 rate-limit·idempotency·receipt
- browser bundle scan에서 control/submission internal URL·credential 0건
- response portal response에 `no-store`, `noindex`, `no-referrer`

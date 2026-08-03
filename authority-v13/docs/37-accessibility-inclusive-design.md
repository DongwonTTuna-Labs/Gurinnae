# 37. 접근성과 포용적 설계

## 1. 기준

구린네는 WCAG 2.2 Level AA와 한국형 웹 콘텐츠 접근성 지침 2.2를 제품 baseline으로 사용한다. 최소 준수 여부만 확인하지 않고, 공공정보를 이해·검증·제출하는 실제 task를 장애 유무와 관계없이 완료할 수 있는지를 acceptance 기준으로 삼는다.

## 2. 원칙

1. native HTML을 우선하고 ARIA는 부족한 semantics를 보완할 때만 사용한다.
2. 키보드와 스크린리더를 별도 모드가 아니라 기본 interaction으로 설계한다.
3. 색상·위치·icon 하나만으로 상태를 전달하지 않는다.
4. 핵심 데이터는 chart와 동등한 table/text를 제공한다.
5. 오류는 사용자가 무엇을 어떻게 수정해야 하는지 설명한다.
6. time limit, token expiry, session expiry는 예고하고 가능한 경우 연장한다.
7. 인지 부담을 낮추되 법적·방법론적 한계를 생략하지 않는다.
8. 공공 기록의 긴 한국어 문장, 숫자, 영문 ID가 혼합되는 상황을 실제 content로 시험한다.

## 3. 문서 구조

- 페이지당 `h1` 하나
- heading level 건너뛰기 금지
- landmark label
- 반복 nav bypass skip link
- breadcrumb는 `<nav aria-label="현재 위치">`
- main content 하나
- related content와 context panel label
- list와 table semantics 유지
- visual card 때문에 의미 없는 heading을 추가하지 않음

## 4. 키보드

모든 기능을 keyboard-only로 수행 가능해야 한다.

필수:

- 논리적 tab order
- visible focus
- focus가 sticky header 아래 숨지 않음
- dialog focus trap과 return
- escape가 안전하게 닫음
- drawer에서 원래 citation으로 return
- drag-and-drop 기능의 keyboard 대안
- table row action의 명확한 접근
- filter chip 삭제
- sortable table header button
- no keyboard trap
- custom shortcut는 help와 비활성화 가능

내부 고밀도 화면에서도 마우스 hover를 primary interaction으로 사용하지 않는다.

## 5. Forms

- 모든 field에 persistent label
- required를 text와 semantics로 표시
- hint는 오류와 구분
- validation은 submit 또는 적절한 시점에 수행; 입력 중 과도한 오류 금지
- error summary가 첫 오류로 focus되고 field 링크 제공
- inline error와 summary 문구 일치
- 입력값 보존
- 날짜·금액·단위 format 예시
- multi-step form의 현재 단계와 전체 단계
- check answers 화면
- destructive submit과 save draft 구분
- autocomplete attribute
- 보안상 필요한 경우를 제외한 paste 차단 금지

## 6. 표와 데이터

### Table

- caption
- header scope
- 단위와 기간
- 복잡한 header association
- horizontal scroll 안내
- keyboard reachable scroll region
- 모바일 대체 카드에서도 필드 label 유지
- 정렬 상태 programmatic announcement
- pagination 결과 변화 live announcement

### Chart

- chart summary
- 대상 data point와 결론
- 동등한 data table
- 색상 외 shape/label
- axis와 unit
- screen reader가 모든 SVG path를 불필요하게 읽지 않도록 처리
- downloadable CSV 또는 JSON
- `prefers-reduced-motion`

### Network graph

graph만으로 관계를 탐색하게 하지 않는다. list/table view가 canonical이다.

## 7. 상태와 알림

- status badge accessible name
- toast는 보조이며 중요한 결과는 페이지에 남음
- async save는 polite live region
- publish/retraction 같은 결과는 receipt page
- loading 상태가 너무 짧게 깜빡이지 않음
- source stale/partial notice는 관련 content 앞에 위치
- icon-only incident indicator 금지

## 8. Zoom·reflow·text spacing

시험:

- 200% browser zoom
- 400% reflow equivalent
- viewport 320 CSS px
- 사용자 text spacing override
- OS large text
- long Korean organization name
- hash/URL wrapping

다음이 없어야 한다.

- 양방향 scrolling이 필요한 일반 본문
- fixed-height clipping
- action button이 viewport 밖으로 사라짐
- sticky panel이 main content를 가림
- table 외 horizontal overflow

## 9. Contrast와 forced colors

- text/interactive contrast AA 이상
- focus indicator 충분한 contrast와 면적
- disabled 상태가 너무 흐리지 않음
- forced-colors에서 border·focus·status 유지
- chart의 target/median 구분 유지
- visited link를 공공 원문 탐색에 유용하게 제공
- placeholder를 label로 사용하지 않음

## 10. 인지 접근성

- 상태 용어에 쉬운 설명
- 전문 용어 glossary
- 긴 workflow를 단계와 task로 분할
- 한 화면에 primary action 하나
- 날짜는 절대 날짜 우선
- 상대 시간은 title 또는 본문에 절대 시각
- ID 복사 가능
- 자동 refresh가 작업을 방해하지 않음
- session expiry 경고와 draft 보존
- 오류 후 사용자가 시작부터 다시 입력하지 않음
- 중요한 미확인 사항을 euphemism으로 숨기지 않음

## 11. 언어

- 기본 `lang="ko"`
- 영문 contract ID나 원문 구간은 필요한 경우 `lang`
- 숫자·통화 screen reader 읽기 검토
- acronym 최초 설명
- 번역을 도입할 경우 언어별 revision과 법적 문구 review
- 기계번역을 공식 소명으로 오인하게 표시하지 않음

## 12. 파일 업로드

- drag-and-drop 외 파일 선택
- 허용 형식·크기 사전 안내
- 파일별 progress와 scan 상태
- 오류를 파일별로 제공
- 제거·재시도
- filename만으로 내용 판단하지 않음
- 이미지/PDF 대체 설명 입력 또는 문서 설명
- CAPTCHA가 필요한 경우 accessible 대안

## 13. Authentication

- passwordless/SSO flow의 focus와 오류
- MFA method 선택
- WebAuthn 실패 fallback
- 인증 timeout 설명
- 오류가 계정 존재를 과도하게 누출하지 않음
- session expired 후 안전한 return
- reauth dialog가 현재 draft를 잃지 않음

## 14. 화면별 접근성 acceptance

모든 screen spec에는 최소한 다음이 있다.

- landmark와 heading
- keyboard task
- focus behavior
- dynamic announcement
- table/chart alternative
- form error behavior
- zoom/reflow
- status semantics

## 15. 시험 매트릭스

자동:

- semantic lint
- axe 계열 검사
- color contrast
- heading/landmark
- generated route crawl

수동:

- keyboard-only
- NVDA + Firefox/Chrome
- VoiceOver + Safari
- mobile screen reader
- 200% zoom
- forced colors
- reduced motion
- form error recovery
- chart/table comparison
- session expiry

자동 검사 통과만으로 접근성 완료를 선언하지 않는다.

## 16. 장애 당사자 연구

공개 사건 이해, 소명 form, 내부 핵심 workflow에 장애 당사자를 포함한 연구를 수행한다. 발견된 문제는 severity와 affected screen/component ID로 기록한다.

## 17. 접근성 statement

Public Web에 다음을 공개한다.

- 적용 기준
- 알려진 제한
- 마지막 검토일
- 문의·대체자료 요청 방법
- 응답 목표
- 향후 개선
- 제3자 원문/PDF의 접근성 한계

## 18. release blocker

다음은 release blocker다.

- 키보드로 게시/소명/정정 핵심 task 완료 불가
- chart에 동등한 데이터 없음
- error summary가 field로 연결되지 않음
- correction/retraction이 screen reader에 전달되지 않음
- 200% zoom에서 핵심 정보 또는 action 손실
- response portal token/session 오류가 이해 불가
- 색상만으로 publication state 구분

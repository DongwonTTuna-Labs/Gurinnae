# 42. 최종 제품·디자인 결정

상태: **DECISION COMPLETE**

## 결정 1 — 정보 위계

공개 사건은 상태와 증거를 먼저 보여준다. 가격 배수·AI 요약·조회수는 hero가 될 수 없다.

## 결정 2 — 세 제품 surface

Public Web, Review Console, Response Portal을 분리한다. 외부 소명 사용자는 내부 Control API에 접근하지 않는다.

## 결정 3 — 공개/내부/제출 API 분리

세 API는 binary, DB role, OpenAPI, generated client, ingress가 분리된다.

## 결정 4 — 계정 없는 공개 열람

공개 기록은 로그인 없이 읽는다. 구독·정정·소명에만 목적별 verification을 사용한다.

## 결정 5 — 순위와 gamification 금지

기관·업체 부패 점수, “가장 구린” 목록, 인기 사건, 좋아요·댓글을 제공하지 않는다.

## 결정 6 — task-based 내부 콘솔

내부 사건 화면은 CRUD 탭 집합이 아니라 next required action, blocker, confirmed/unknown을 중심으로 구성한다.

## 결정 7 — destructive interaction과 security assurance 분리

게시·정정·철회·rule 활성화·source 중지·kill switch·role 변경에는 exact target, diff,
expected version, reason, audit receipt가 필요하며 recent reauth는 `assurance_level: STEP_UP` operation에만 적용한다.

## 결정 8 — 최종 시각 체계

warm paper + ink + evidence blue를 기본으로 한 공공 기록 데이터룸 디자인을 확정한다.
Design token, component anatomy, grid와 responsive order는 machine-readable contract다.

## 결정 9 — 원샷 완제품

내부 구현 순서는 허용하지만 납품 범위는 나누지 않는다. 94개 화면, 215개 operation,
DB·jobs·auth·deployment가 한 source tree에 완성돼야 한다.

## 결정 10 — 설정만 외부 입력

코드로 결정할 수 없는 것은 domain, secret, OIDC, mail, object storage, source key,
선택적 AI provider credential뿐이다. 이름과 startup semantics는 config catalog에 고정돼 있다.

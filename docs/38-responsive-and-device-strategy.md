# 38. 반응형·기기 전략

## 1. 목적

반응형 설계는 데스크톱 화면을 축소하는 작업이 아니다. 기기별 사용 맥락과 정보 우선순위를 보존해야 한다. 특히 공개 사건은 모바일 공유 링크로 처음 접할 가능성이 높고, 내부 콘솔은 넓은 화면이 주 사용 환경이지만 긴급 승인·incident 확인은 작은 화면에서도 발생할 수 있다.

## 2. 범위

| 범위 | Compact | Medium | Wide | Extra-wide |
|---|---:|---:|---:|---:|
| CSS width | `<640px` | `640–1023px` | `1024–1439px` | `>=1440px` |
| 공개 웹 | 완전 지원 | 완전 지원 | 완전 지원 | 완전 지원 |
| Response Portal | 완전 지원 | 완전 지원 | 완전 지원 | 제한 폭 |
| Review Console | 핵심 read/approval 지원 | 주요 task 지원 | 완전 지원 | 완전 지원 |

breakpoint는 특정 기기 이름이 아니라 content가 깨지는 지점으로 조정할 수 있다. token 변경은 ADR가 아니라 design token review를 거친다.

## 3. 공개 웹

### Compact

- header: logo/서비스명, search, menu
- 사건 top hierarchy 보존
- Known → Unknown → Response 순서로 stack
- metric은 2열 이하
- chart 다음에 table toggle 또는 바로 table
- evidence drawer는 full-height sheet
- filter는 modal/sheet
- selected filter count
- sticky share bar보다 content 우선
- 긴 계약명 wrap
- correction banner가 접히지 않음

### Medium

- 2열 metric
- content + optional aside
- search filter sheet 또는 side panel
- comparison table horizontal scroll

### Wide

- 본문 8–9 columns, context 3–4 columns
- evidence context panel 가능
- long form 폭 제한
- 글로벌 nav 확장

### Extra-wide

- 텍스트 줄 길이를 늘리지 않는다.
- timeline, evidence, related context에 공간 사용
- 3열 이상의 card grid는 의미가 있을 때만

## 4. 내부 콘솔

### Wide baseline

사건 workspace:

```text
global nav | task rail | main task | context panel
```

필요에 따라 context panel을 접는다.

### Medium

- global nav collapses
- task rail는 상단 selector 또는 drawer
- main + context 2영역
- queue column 일부 숨김 대신 column chooser
- high-impact action footer가 content를 가리지 않음

### Compact

지원해야 할 핵심 task:

- 알림 확인
- 내 작업 확인
- 사건 상태·blocker 읽기
- review snapshot 읽기
- 긴급 hold/incident acknowledgement(정책상 허용 시)
- MFA/reauth
- audit receipt 확인

복잡한 task는 “모바일 미지원”으로 끝내지 않고 안전한 read-only 또는 desktop-required 안내를 제공한다.

모바일에서 기본 금지:

- 복잡한 cohort 편집
- entity merge
- schema mapping
- bulk replay
- rule threshold activation
- 대량 role 관리

단, 권한을 브라우저 크기로 판단하지 않으며 server command는 별도 정책으로 보호한다.

## 5. Response Portal

mobile-first다.

- 한 단계에 하나의 논리적 질문
- large touch target
- file upload camera/photo 문서 처리 안내
- save state 명확
- keyboard에 가려지지 않는 next/submit
- 긴 privacy 문구는 요약 + 전체
- check answers에서 edit link
- connection interruption recovery

## 6. Table 전략

우선순위:

1. 필수 column을 유지한 scroll table
2. column chooser
3. row detail expansion
4. card 변환

card 변환 시 label과 관계를 잃지 않는다. 금액·단위·날짜를 한 줄에 압축해 의미를 잃지 않는다.

sticky first column은 screen reader와 keyboard를 방해하지 않게 시험한다.

## 7. Chart 전략

- compact에서는 단순화하되 sample size와 axis를 제거하지 않음
- tooltip만 있는 detail은 아래 표로 제공
- pinch zoom에 의존하지 않음
- legend wrap
- target와 median label 직접 표시
- network graph는 compact에서 list 우선

## 8. Navigation

Public compact:

- search를 최상위
- menu open 시 body scroll 관리
- 현재 route 표시
- Escape와 focus return
- footer navigation 완전 제공

Internal compact:

- surface name과 environment banner
- critical incident badge
- role/account
- local task nav 별도

## 9. Orientation과 touch

- portrait/landscape 모두 핵심 task
- hover-only 금지
- 최소 touch target baseline
- double tap 같은 비표준 gesture 금지
- swipe는 보조
- destructive action proximity 주의
- iOS safe area
- virtual keyboard와 validation scroll

## 10. 성능

모바일 네트워크에서:

- SSR로 핵심 내용 우선
- chart는 progressive enhancement
- 큰 evidence PDF 자동 다운로드 금지
- image thumbnail 최적화
- pagination
- public case initial JS budget
- response draft retry와 idempotency
- internal live update는 backoff

## 11. Print와 export

공개 사건은 인쇄/저장 시 다음을 유지한다.

- title, state, revision, URL
- publication/correction date
- known/unknown/response
- metrics
- evidence citation
- methodology
- page break
- interactive-only UI 제거

내부 화면 print는 민감정보 위험 때문에 기본 제한 또는 watermark/audit.

## 12. 시험 viewport

최소 visual/functional matrix:

- 320×568
- 360×800
- 390×844
- 768×1024
- 1024×768
- 1280×800
- 1440×900
- 1920×1080

기기 pixel snapshot만이 아니라 200% zoom과 dynamic text도 시험한다.

## 13. Acceptance

- 모바일 사건 상세에서 Known/Unknown/Response가 모두 첫 주요 흐름에 있다.
- filter 적용·제거·공유가 가능하다.
- table 정보가 카드 변환에서 손실되지 않는다.
- internal compact에서 unsupported task가 안전하게 설명된다.
- response form이 keyboard/connection interruption에서 답변을 잃지 않는다.
- extra-wide에서 긴 본문 줄 길이가 늘어나지 않는다.

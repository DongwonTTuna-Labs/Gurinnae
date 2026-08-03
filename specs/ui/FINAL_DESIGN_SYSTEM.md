# 구린네 Final Design System

상태: **FINAL**  
이 문서는 색상 참고안이 아니라 실제 구현 계약이다. 화면마다 다른 스타일을 발명하지 않는다.

## 1. 디자인 목표

구린네의 첫 인상은 “폭로 사이트”가 아니라 **검증 가능한 공공 기록 데이터룸**이어야 한다.
사용자는 자극적인 결론보다 다음을 가장 빠르게 이해해야 한다.

1. 지금 어떤 상태의 기록인가
2. 무엇이 확인됐는가
3. 무엇이 아직 확인되지 않았는가
4. 당사자는 무엇이라고 답했는가
5. 비교와 계산은 어떻게 만들어졌는가
6. 어떤 원본 근거가 있는가
7. 이후 무엇이 바뀌었는가

## 2. 시각 방향

- 따뜻한 종이색 canvas와 짙은 ink text를 기본으로 한다.
- Evidence blue는 링크·주요 action·근거 navigation에만 쓴다.
- Green은 설명 확인·정상 상태, amber는 미확인·주의, red는 정정·철회·파괴적 행동에 쓴다.
- AI output은 violet로 구분하며 결정적 근거와 같은 위계를 갖지 못한다.
- 카드 남용을 금지한다. 서로 관련된 정보는 section, rule, table로 연결한다.
- decorative gradient, glass blur, oversized metric hero를 금지한다.
- 공개 기록은 whitespace가 충분한 editorial layout, 내부 콘솔은 dense task layout을 사용한다.

## 3. Public Web composition

### Header

- 높이 68px
- 왼쪽: wordmark
- 중앙: `사례`, `계약`, `기관·업체`, `방법론`, `데이터 범위`, `정정`
- 오른쪽: 검색, 구독
- compact에서는 wordmark, search, menu만 남긴다.
- global source incident가 있으면 header 아래에 persistent status strip을 둔다.

### Home above the fold

1. 작은 eyebrow: `공개자료를 근거로, 설명이 필요한 차이를 찾습니다`
2. H1: 서비스가 무엇을 하는지 설명
3. 한계 문장: 자동 부패 판정이 아님
4. 통합 검색
5. 데이터 최신성·범위 summary

`최근 이상 사례 Top 10`이나 가격 배수 leaderboard를 넣지 않는다.

### Case detail above the fold

1. correction/retraction/legal restriction banner
2. breadcrumb
3. public status + revision + published/updated time
4. plain-language title
5. 2–3문장 summary
6. Known / Critical unknown / Response
7. mobile에서는 동일 순서로 stack

가격 비교 chart는 위 영역 아래에 위치한다.

## 4. Internal Console composition

### Shell

- left sidebar 248px
- top bar 56px
- optional task rail 232px
- optional context panel 360px
- center content is fluid
- status and assignment are always visible
- keyboard shortcut palette is optional but all functions remain reachable by visible controls

### Case workspace

Header:
- case id/title
- internal state
- expected version
- assignment
- save state
- primary next action

Body:
- task rail: Overview, Signals, Hypotheses, Evidence, Claims, Responses, Agents, Review, Publication, Timeline, Audit
- center: selected task
- right: blockers, critical unknowns, related objects

AI chat is not a permanent primary column.

## 5. Response Portal composition

- single-column max 760px
- one logical question per step
- request identity and deadline always visible
- draft save status always visible
- attachment quarantine/scan state explicit
- final review shows exactly what may be published
- submission returns immutable receipt

## 6. Typography

Exact tokens are in `design-tokens.yaml`.

- Display is used only on home or major policy landing.
- Public record title uses H1, not display.
- Body uses 1rem/1.62.
- Long-form maximum is 72ch.
- Data uses tabular numerals.
- Korean labels do not use all-caps.

## 7. Spacing and grouping

- related label/value: 4–8px
- component internals: 12–16px
- sibling components: 20–24px
- section groups: 32–48px
- major page regions: 64–96px

Border and whitespace establish hierarchy before shadow.

## 8. States

Every data component supports:

- initial loading
- background refresh
- empty
- filtered empty
- partial
- stale
- unavailable source
- error with retry
- unauthorized/forbidden where applicable
- optimistic conflict where applicable

Skeleton shape must match final content and must not display invented values.

## 9. Responsive behavior

- `compact`: one column, bottom sheet/drawer for context, no horizontal layout dependency
- `medium`: two-column where reading remains clear
- `wide`: full grids and sticky context
- tables become prioritized record cards only when column meaning remains explicit
- no desktop-only critical action
- no horizontal scroll as the only mobile solution for primary tasks

## 10. Accessibility

- WCAG 2.2 AA target
- visible skip links
- one H1
- landmark labels
- 44px touch targets
- focus is never hidden by sticky UI
- error summary links to fields
- charts have table equivalent
- status not color-only
- dialogs return focus
- updates announced without stealing focus
- 200% zoom and 320 CSS px reflow

## 11. Copy

- “이상 징후”와 “비리”를 구분한다.
- “확인”, “미확인”, “소명”, “정정”을 명시적으로 쓴다.
- 무응답은 인정이 아니다.
- AI confidence를 사실 가능성이나 부패 확률로 번역하지 않는다.
- action label은 결과를 말한다: `게시 승인`, `정정 revision 공개`, `source 수집 일시 중지`.

## 12. Implementation test

Visual implementation is accepted only when:

- token use is semantic
- screen order matches screen build manifest
- desktop/medium/compact screenshot tests pass
- representative user comprehension tests have no misleading hierarchy
- no forbidden style or metric hero appears

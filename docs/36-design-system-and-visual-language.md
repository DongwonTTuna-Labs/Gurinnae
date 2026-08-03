# 36. 디자인 시스템과 시각 언어

상태: **FINAL**

구린네의 최종 시각 계약은 `specs/ui/FINAL_DESIGN_SYSTEM.md`,
`design-tokens.yaml`, `FINAL_COMPONENT_MANUAL.md`가 권위다.

## 디자인 명제

**공공 기록 보관소와 탐사 데이터룸의 신뢰감을 결합한 증거 우선 인터페이스**

사용자는 선정적인 결론보다 상태, 확인된 사실, 중요한 미확인, 소명,
비교 조건, 반대 근거, 원본 provenance, revision을 순서대로 본다.

## Brand

- 이름: 구린네
- descriptor: 공공계약 이상 징후 조사 플랫폼
- personality: 차분함, 정확함, 검증 가능함, 공익성, 비선정성
- 금지: 범죄 게임, 네온 해커, 투자 터미널, AI 판결, gamified ranking

## Color

- canvas: warm paper
- text: high-contrast ink
- evidence/action: restrained evidence blue
- verified/explained: green
- unknown/stale: amber
- correction/retraction/destructive: red
- AI assistance: violet

Red는 generic suspicion에 쓰지 않는다. 상태는 색상만으로 표현하지 않는다.

## Typography

- Korean UI/body: Noto Sans KR와 system fallback
- long form: 최대 72ch
- body: 16px 이상, 1.62 line height
- data: tabular numerals
- hash/code: monospace
- 외부 font CDN 없음

## Layout

- Public: 1280px, 12-column
- Case detail: main 8 + sticky context 4
- Internal: 248px nav + 232px task rail + fluid content + 360px context
- Response: max 760px single-column
- compact/medium/wide/extra-wide breakpoints는 token file에 고정
- 주요 touch target 44px 이상

## Component policy

카드가 기본 container가 아니다. 정보 관계는 heading, whitespace, divider, table로 먼저 표현한다.
Evidence, comparison, decision, correction, status는 전용 policy-bearing component를 사용한다.

## Final proof

- semantic token 사용
- 94개 screen hierarchy 일치
- desktop/tablet/mobile visual regression
- WCAG 2.2 AA
- chart/table equivalence
- no forbidden visual pattern

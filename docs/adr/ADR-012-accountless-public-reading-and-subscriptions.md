# ADR-012: 계정 없는 공개 열람과 이메일 구독

- 상태: Accepted
- 날짜: 2026-07-10
- 결정자: Product/Editorial/Architecture
- 관련: `docs/27-product-strategy-and-principles.md`, `docs/34-response-correction-and-notification-flows.md`

## Context

공공계약·정정·방법론은 공익적 공개 정보다. 이를 열람하기 위해 계정 생성을 요구하면 접근 장벽, 개인정보 보유, 인증 운영 비용이 증가한다. 다만 사건·기관·업체 업데이트를 받고 관리하려는 사용자는 구독 식별이 필요하다.

## Decision

- Public Web의 모든 핵심 읽기는 anonymous로 제공한다.
- 전통적인 password account를 public reader에게 요구하지 않는다.
- 구독은 이메일 verification link로 활성화한다.
- 구독 관리는 짧은 수명의 magic management link로 수행한다.
- correction request도 계정 없이 제출하고 receipt/magic status link를 제공한다.
- 구독 이메일은 public browsing analytics identity와 결합하지 않는다.
- user profile, follower count, public activity history를 만들지 않는다.

## Consequences

장점:

- 공공정보 접근성 향상
- credential 저장·reset·account takeover 범위 감소
- public social feature로의 오해 방지

비용:

- magic link 보안·만료·replay 방지 필요
- 이메일 delivery/bounce/suppression 필요
- 여러 주소 구독 병합이 복잡
- 사용자가 link를 잃으면 재검증 필요

## Rejected alternatives

- 모든 공개 사용자의 회원가입
- 소셜 로그인
- browser localStorage만으로 구독 관리
- 개인화 recommendation profile

## Fitness tests

- 인증 없이 모든 공개 사건과 방법론 접근
- 구독 verification 전 알림 미발송
- magic link가 다른 목적에 사용되지 않음
- 이메일이 analytics event에 포함되지 않음
- one-click unsubscribe

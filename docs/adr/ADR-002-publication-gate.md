# ADR-002: 인간 전용 공개 게이트와 immutable revision

- Status: Accepted
- Date: 2026-07-10

## Context

AI와 규칙이 실제 기관·업체에 대한 평판 손상을 일으킬 수 있다. UI 버튼 숨김만으로는 자동화·API·DB 우회를 막지 못한다. 승인 후 내용 변경도 승인 의미를 무너뜨린다.

## Decision

- AI/service account는 ReviewDecision actor가 될 수 없다.
- publication은 `READY_TO_PUBLISH`와 모든 guards가 필요.
- approvals는 exact `ReviewSnapshot.content_hash`에 결합.
- medium/high risk는 작성자와 독립된 복수 승인.
- high risk는 legal approval.
- PublicationRevision은 immutable; correction/retraction은 새 revision.
- public projection 활성화는 승인 hash와 atomic하게 검증.
- public API는 editorial tables가 아니라 approved public schema만 읽음.

## Consequences

- 자동 속도보다 정확성과 책임 우선
- 작은 수정도 재승인이 필요할 수 있음
- audit와 correction 신뢰 증가
- 운영자 DB 직접 수정 금지와 emergency path 설계 필요

## Emergency

PII/security harm는 body 임시 access restriction을 허용하지만:

- reason/actor/audit 필수
- 원본 삭제가 아니라 보호 상태
- 4시간 내 책임자 review 목표
- correction/retraction 절차 후속

## Rejected

- 모델 confidence threshold 자동 공개
- 한 명 admin 만능 승인
- mutable article row overwrite
- “초안 공개”라는 이름의 무검토 public page

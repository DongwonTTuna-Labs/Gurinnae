# Flow 03 — Signal에서 공개까지

```mermaid
flowchart TD
  A[SIG-001 Queue] --> B[SIG-002 결정적 계산 검토]
  B --> C{Triage}
  C -- 제외 --> D[Reason code + audit]
  C -- 추가 자료 --> E[Task 생성]
  C -- 기존 사건 --> F[CAS-003 연결]
  C -- 사건 승격 --> G[CAS-002 Overview]
  G --> H[CAS-007 가설]
  H --> I[CAS-004/005 근거]
  I --> J[CAS-008/009 소명]
  J --> K[CAS-006 Claim]
  K --> L[CAS-013 Readiness]
  L --> M[Review snapshot]
  M --> N[REV-002 독립 검토]
  N --> O{승인?}
  O -- 변경 요청 --> K
  O -- 승인 --> P[CAS-014 Preview]
  P --> Q[REV-003 게시 확인]
  Q --> R[Public projection]
  R --> S[PUB-004 공개]
```

## 불변조건

- AI output은 Signal calculation과 source evidence를 대체하지 않는다.
- factual claim은 evidence 없이 저장되지 않는다.
- response gate와 반대 근거 review를 건너뛰지 않는다.
- 변경된 case는 이전 snapshot approval을 재사용하지 않는다.
- 게시 command가 서버에서 모든 gate를 다시 계산한다.

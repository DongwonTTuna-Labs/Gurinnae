# Flow 04 — 소명 요청과 제출

```mermaid
flowchart TD
  A[CAS-009 요청 작성] --> B{contact·legal gate}
  B -- 실패 --> A
  B -- 통과 --> C[Control API request 생성]
  C --> D[Submission projection + token]
  D --> E[안전한 이메일 전달]
  E --> F[RSP-001 진위·기한 확인]
  F --> G[RSP-002 질문 확인]
  G --> H[RSP-003 답변 draft]
  H --> I[RSP-004 첨부·검사]
  I --> J[RSP-005 Check answers]
  J --> K[Submission API 제출]
  K --> L[RSP-006 Receipt]
  K --> M[내부 intake queue]
  M --> N[CAS-008 검증·공개 excerpt]
```

## 경계

- Response Portal은 Control API를 호출하지 않는다.
- token은 다른 request를 조회할 수 없다.
- 제출은 publication 상태를 변경하지 않는다.
- 파일 검사 완료 전 최종 제출할 수 없다.
- third-party analytics와 referrer token 유출을 금지한다.

# 내부 독립 Review·게시 Wireframe

## Review Queue

```text
[age] [risk] [source stale] [response] [author conflict]
Case · snapshot hash · created by · policy version · unresolved gate · SLA
```

## Snapshot Review

```text
┌───────────────────────────────────────────────────────────────────────┐
│ Independent review · snapshot 2222… · case v12                        │
│ Author: Investigator A · You: Editor B · SOD PASS                     │
├───────────────────────────────────────────────────────────────────────┤
│ Diff from previous snapshot / policy checks / freshness                │
├───────────────────────────────┬───────────────────────────────────────┤
│ Publication preview           │ Review checklist                      │
│ exact public rendering        │ evidence completeness                 │
│ known/unknown/response        │ identity                              │
│ charts/tables/citations       │ prohibited language                   │
│ correction/history           │ response right                        │
│                               │ accessibility preview                 │
├───────────────────────────────┴───────────────────────────────────────┤
│ Decision reason [required textarea]                                   │
│ [Reject] [Approve exact snapshot]                                     │
└───────────────────────────────────────────────────────────────────────┘
```

## Publish confirmation

- exact case, snapshot hash, content hash, display status, scheduled time, target origin을 표시한다.
- recent MFA/reauth 후에도 서버가 SOD·version·gate를 재검사한다.
- stale snapshot은 confirm dialog조차 열 수 없다.
- 성공 receipt에는 publication revision ID, actor, policy version, timestamp, request ID를 제공한다.
- 실패 시 “다시 시도”가 중복 게시를 만들지 않도록 같은 idempotency key의 상태를 조회한다.

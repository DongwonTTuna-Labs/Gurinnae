# 내부 Signal Triage Wireframe

```text
┌────────────────────────────────────────────────────────────────────────┐
│ Signals / Unassigned · 34                                              │
├───────────────┬──────────────────────────────────────┬─────────────────┤
│ Saved views   │ Signal list                          │ Selected signal │
│ New 34        │ [rule] [source] [age] [blocker]      │ SG-001 v3       │
│ Blocked 12    │                                      │                 │
│ Needs data 8  │ SG-001 PRICE_OUTLIER 5.0x            │ 계산            │
│ Duplicates 3  │ 12 comparable · no hard blocker      │ 대상 2.4m       │
│               │ source fresh 2h · identity verified  │ median .48m     │
│               │                                      │ n=12            │
│               │ SG-002 BUNDLE_UNKNOWN                │                 │
│               │ publishability BLOCKED               │ blocker/unknown │
│               │                                      │ evidence refs   │
├───────────────┴──────────────────────────────────────┤ counter/AI      │
│ Bulk actions: assign only. Merge/dismiss never bulk. │ suggestion      │
│                                                     │                 │
│                                                     │ [Create case]   │
│                                                     │ [Need data]     │
│                                                     │ [False positive]│
└──────────────────────────────────────────────────────┴─────────────────┘
```

## 우선순위

1. 결정적 계산과 입력 snapshot
2. 비교 cohort 포함·제외
3. blocker와 중요한 미확인
4. source freshness·identity quality
5. 관련 signal/case 중복
6. 반대 가설
7. AI 제안
8. 허용된 다음 action

## 행동 규칙

- `Create case`, `False positive`, `Merge`는 이유와 expected version을 요구한다.
- AI suggestion을 상단 hero나 primary action으로 만들지 않는다.
- ratio만으로 queue를 정렬하지 않는다. freshness, blocker, data quality, public interest policy를 함께 사용한 투명한 triage policy가 필요하다.
- keyboard로 list 이동 시 context panel heading과 live region을 과도하게 갱신하지 않는다.
- compact에서는 list와 detail을 별도 route처럼 전환하고 back navigation이 필터·scroll을 보존한다.

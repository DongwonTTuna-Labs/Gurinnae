# 내부 조사·검토 Console Wireframe

```text
┌──────────────────────────────────────────────────────────────────────────┐
│ GURINE REVIEW · STAGING   [Source health] [Ops] [User]                  │
├───────────────┬──────────────────────────────────────────────────────────┤
│ Queue         │ GRN-2026-000001 · v12 · EDITORIAL_REVIEW               │
│ Signals 34    │ Expected version: 12             [Assign] [Add note]    │
│ Triage 12     ├──────────────────────────────────────────────────────────┤
│ Investigating │ Tabs: Overview Signals Evidence Claims Responses Agents │
│ Responses 4   │       Timeline Review Preview Corrections Audit         │
│ Review 6      ├──────────────────────────────────────────────────────────┤
│ Corrections 1 │ Readiness                                                │
│               │ ✓ subject identity verified                             │
│ Filters       │ ✓ 2 independent comparison evidence sets                │
│ age/rule/risk │ ✓ skeptic review completed                              │
│ owner/source  │ ! response window ends in 2 days                        │
│               │ ✕ review snapshot not created                           │
│               ├──────────────────────────────────────────────────────────┤
│               │ Claims                                                   │
│               │ C-001 FACT VERIFIED [evidence 2] [history]              │
│               │ C-002 INTERPRETATION DRAFT [prohibited-word lint: 0]    │
│               │ C-003 LIMITATION VERIFIED [evidence 1]                  │
│               ├──────────────────────────────────────────────────────────┤
│               │ Conflicts / legal risk                                  │
│               │ none · publication risk MEDIUM                          │
│               ├──────────────────────────────────────────────────────────┤
│               │ [Create immutable review snapshot]                       │
└───────────────┴──────────────────────────────────────────────────────────┘
```

## Review snapshot 화면

```text
Snapshot 2222... created 2026-01-29T01:00Z
Content: case v12 / claims 3 / evidence 15 / responses 1 / rule 1.0.0

Policy checks
PASS evidence completeness
PASS subject identity
PASS language lint
PASS response requirement
PASS source freshness
N/A  legal review

[Approve this snapshot] [Reject with reason]
```

승인 이후 claim/evidence가 변경되면 상단에 다음을 표시한다.

```text
STALE APPROVAL — case content changed after snapshot.
Previous approval cannot be used for publication.
[Review diff] [Create new snapshot]
```

## Conflict 처리

다른 편집자가 먼저 case v13을 저장했다면:

```text
Save rejected: expected v12, current v13.
Your draft is preserved locally. Review the server diff before reapplying.
[Open diff] [Discard local draft]
```

자동 last-write-wins 금지.

## Agent run panel

- 역할, input snapshot hash, model, prompt version
- tool domains, citations, cost
- schema validation
- prompt injection warnings
- result는 “제안”으로만 표시
- `Apply all` 버튼 금지; claim/evidence별 사람이 선택하고 이유 기록

# 내부 사건 Workspace Wireframe

```text
┌────────────────────────────────────────────────────────────────────────┐
│ GRN-SYNTH-001 · INVESTIGATING · v12 · owner · due date                 │
│ Next task: verify bundle contents             [Transition] [Assign]     │
├───────────────┬────────────────────────────────────────┬───────────────┤
│ Task groups   │ Main workspace                         │ Context rail  │
│ Overview      │ Known                                  │ Gate status   │
│ Investigation│ · source-backed facts                  │ identity ✓    │
│  Signals      │ · calculations                         │ evidence !    │
│  Evidence     │ Unknown                                │ response …    │
│  Hypotheses   │ · certification cost                  │ legal N/A     │
│  Agents       │ Responses                              │               │
│ Authoring     │ · requested/received/verified          │ Activity      │
│  Claims       │ Counter evidence                       │ recent events │
│  Response     │                                       │               │
│ Review        │ [Add evidence] [Write claim]            │               │
│ Records       │                                       │               │
├───────────────┴────────────────────────────────────────┴───────────────┤
│ Unsaved draft preserved · server v12 · no conflict                    │
└────────────────────────────────────────────────────────────────────────┘
```

## Workspace 원칙

- 첫 화면은 entity tab 목록이 아니라 현재 상태, 다음 결정, blocker를 보여준다.
- task group route는 deep-link 가능하고 browser back/refresh 후에도 선택 상태를 복원한다.
- evidence와 claim은 optimistic version을 사용하며 conflict에서 local draft를 보존한다.
- context rail은 보조 정보다. compact에서는 별도 panel로 이동하되 gate와 next task는 main에 남긴다.
- unsaved state, background save, final submit을 명확히 구분한다.
- agent run은 별도 structured record이며 대화 transcript가 사건의 machine truth가 아니다.

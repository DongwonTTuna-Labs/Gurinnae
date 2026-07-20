# 내부 Source·Rule·Operations Wireframe

## Source 상세

```text
Source status / last success / expected cadence / lag / parser version
Recent runs / schema drift diff / quarantine / checkpoints / affected projections
[Pause source] [Acknowledge incident] [Create parser change task]
```

- raw sample은 민감 필드를 마스킹하고 다운로드 권한을 별도로 검사한다.
- schema drift에서는 removed/added/type changed/semantic changed를 구분한다.
- source pause는 이유, 예상 영향, 재개 조건, reauth, audit receipt를 요구한다.

## Rule 상세·평가

```text
Active version / draft version / cohort definition / blockers / threshold
Evaluation: precision, false-positive set, excluded cases, regressions
Diff / reviewer / activation window / rollback target
```

- activation은 단일 switch가 아니라 evaluation artifact와 independent approval을 요구한다.
- 실제 기관 leaderboard를 평가 화면에 만들지 않는다.
- rule 변경으로 생성되는 signal volume estimate와 비용 영향을 표시한다.

## Operations

- queue/DLQ, job detail, provider status, 비용, kill switch를 분리한다.
- kill switch는 scope, 현재 상태, downstream impact, recovery plan과 break-glass reason을 표시한다.
- dashboard chart는 action 가능성이 없는 vanity metric을 기본 화면에 두지 않는다.
- audit log는 product analytics와 분리하고 immutable event locator를 제공한다.

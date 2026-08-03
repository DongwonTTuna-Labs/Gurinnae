# UI generator parity and structure-lint evidence

검증 시각(UTC): 2026-07-19

권위 팩 SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`

현재 source tree의 권위 입력으로 생성물을 재생성한 뒤 check 모드와 effective
registry를 순서대로 실행했다. 생성기는 `specs/ui`의 effective contract,
action, state, accessibility, journey 문서를 결정적으로 작성한다.

```text
python3 -B scripts/generate_effective_ui_contracts.py
PASS

python3 -B scripts/generate_effective_ui_contracts.py --check
PASS (exit 0)

python3 -B scripts/generate_effective_registry.py --json-output /tmp/registry.json
STRUCTURE_LINT: PASS
problem_count: 0

python3 -B scripts/validation/design_freeze.py --mode lint \
  --json-output /tmp/design-freeze-lint.json
STRUCTURE_LINT: PASS
RELEASE_FREEZE: NOT_RUN
structure_problem_count: 0

python3 -B scripts/validation/effective_acceptance.py --mode contract
EFFECTIVE_ACCEPTANCE_CONTRACT: PASS

python3 -B scripts/validation/effective_acceptance.py --mode source
EFFECTIVE_ACCEPTANCE_SOURCE: PASS
```

Effective registry counts from `/tmp/registry.json`: 94 screens, 496 sections,
332 screen actions, 277 operations, 173 commands, 187 events, 30 migrations,
439 effective tests. The generated output intentionally removes the
non-authority `OPS-004.business-health` section (497→496) and normalizes the
closed enum/const type notation. This evidence closes only the generator-parity
and structure-lint blocker; it is not a product/design or business-model LGTM.

## Post-change rerun

Business/SLA migration edits landed in the shared worktree after the initial
run. The same checks were rerun against that newer source tree:

- `generate_effective_ui_contracts.py --check`: PASS
- `effective_acceptance.py --mode contract`: PASS (0 problems)
- `effective_acceptance.py --mode source`: PASS (0 problems)
- `generate_effective_registry.py`: `STRUCTURE_LINT: PASS`
- `design_freeze.py --mode lint`: `STRUCTURE_LINT: PASS`,
  `structure_problem_count: 0`, `RELEASE_FREEZE: NOT_RUN`

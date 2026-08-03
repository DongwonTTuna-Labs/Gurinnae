# Evaluation datasets

- `gold-cases.jsonl`: 정확한 탐지 또는 정확한 blocker를 기대하는 24개 합성 평가 항목
- `false-positive-cases.jsonl`: 공개 가능한 이상 사건으로 승격해서는 안 되는 30개 합성 항목
- `evaluation-rubric.md`: 100점 평가, hard-fail, release gate

각 줄은 독립 JSON 객체다. `FIXTURE` 항목은 저장소 파일로 즉시 실행할 수 있다. `SCENARIO` 항목은 해당 마일스톤에서 executable fixture와 test로 승격한다. 기대 결과를 현재 코드에 맞추어 조용히 변경하지 않는다.

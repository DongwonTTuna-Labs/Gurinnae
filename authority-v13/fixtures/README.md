# Synthetic fixtures

모든 fixture는 실제 기관·업체·계약과 무관한 합성 자료다. `.invalid` URL만 사용하며 실제 비리나 의혹을 표현하지 않는다.

## 핵심 시나리오

- `price_target` + `price_cmp_01..12`: 비교 가능한 가격 이상 신호와 공개 gate
- `bundle_explained`: 묶음 구성으로 설명된 오탐 통제
- `bundle_unknown`, `unit_mismatch`, `vat_unknown`, `identity_ambiguous`, `cancelled`: 공개 blocker
- `split_01..04`: 계약 분할 패턴 lead
- `amendment_escalation`: 변경계약 증가 lead
- `schema_drift`: 격리와 source pause
- `prompt_injection`: 문서 텍스트를 명령으로 처리하지 않음
- `duplicate_observation`: content identity reconciliation

Fixture는 모델 품질을 과장하는 demo가 아니라 deterministic acceptance test의 입력이다.

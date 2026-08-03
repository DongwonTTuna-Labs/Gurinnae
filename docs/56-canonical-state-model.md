# 56. Canonical State Model

상태: **FINAL**

사건 상태는 `investigation_state`, `publication_state`, `resolution_code` 세 축으로 관리한다. 권위 파일은 `specs/domain/state-machines.yaml`이다. Rust enum, SQL, JSON Schema, OpenAPI filter와 UI label은 이 값과 정확히 일치해야 한다. 전이는 capability, guard, audit action과 event를 함께 가진다.

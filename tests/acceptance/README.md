# Final Acceptance Contracts

모든 `.feature`는 단일 최종 release의 hard gate다.

- `@hard-gate`: 실패하면 release 불가
- `@final`: 원샷 완제품 범위
- 나머지 tag: domain, security, UI, operations 분류

Acceptance test는 실제 구현에서 executable test로 매핑한다.
단순 문서 확인만으로 behavior test를 대체하지 않는다.

필수 증거:

- scenario ID와 test file
- 실행 명령
- PostgreSQL/Docker/browser 환경
- exit code와 pass count
- artifact/screenshot/log
- 실패 시 정확한 gate

Skip, pending, quarantine은 명세가 명시적으로 허용하지 않는 한 실패다.

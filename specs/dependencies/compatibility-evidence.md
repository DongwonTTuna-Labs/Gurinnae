# Dependency Compatibility Evidence Contract

상태: **FINAL IMPLEMENTATION GATE**

이 사양은 exact desired versions를 고정한다. Codex가 실제 source tree를 materialize한 뒤 clean network-enabled environment에서 다음을 증명해야 한다.

- Cargo.lock과 bun.lock이 두 번의 clean resolution에서 동일하다.
- Rust workspace `cargo check --workspace --all-targets --all-features --locked` 통과.
- SQLx live prepare와 offline build 통과.
- Bun clean install, SvelteKit check/build, Bun production SSR startup 통과.
- 세 API OpenAPI 생성과 세 TypeScript client의 deterministic regeneration 통과.
- Linux amd64와 실제 배포 architecture smoke 통과.
- SBOM, license policy, vulnerability scan, first-party unsafe zero 증거 첨부.

호환성 실패 시 Codex는 임의 upgrade/downgrade하지 않고, 최소 범위 ADR과 재검증 증거를 같은 최종 artifact에 포함한다.

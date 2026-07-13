# Codex Handoff — 구린네 전체 구현

아래 요청을 이 archive 전체와 함께 Codex에 전달한다.

---

You are implementing the complete Gurine product from the attached authority pack.

Treat `AGENTS.md`, `FINAL_BUILD_CONTRACT.md`, and the authority order declared in `AGENTS.md` as binding. Read the entire relevant specification before editing.

Deliver the complete desired outcome, not an MVP, scaffold, partial vertical slice, plan-only response, or follow-up milestone. You may work in small internal commits and run as many build/test/fix loops as necessary, but return only a complete verified source-tree artifact.

Hard requirements:

1. Implement every declared Cargo member, Bun workspace, service, database migration, operation, screen, connector, parser, agent and rule.
2. Use Rust 1.97.0, Actix Web, Tokio, SQLx, PostgreSQL 18.4, Svelte 5, SvelteKit SSR, Bun and Biome exactly as specified.
3. First-party Rust must contain no `unsafe`, FFI, production `unwrap`, `expect`, `panic!`, `todo!`, `unimplemented!`, or `unreachable!`. Every crate root must use `#![forbid(unsafe_code)]`.
4. Write idiomatic Rustful and Svelteful code. Enforce SOLID without speculative abstractions, YAGNI, Clean Code, file/function limits and strict layer boundaries.
5. Implement the request-bound Service/Actor Assertion protocol, bounded step-up retry grant, encrypted envelopes and PostgreSQL replay protection exactly as specified; do not replace them with a simpler browser-cookie Control API.
6. Implement the exact parser/OCR selection and sandbox; do not substitute a generic text extractor.
7. Do not weaken, delete or skip any required test or acceptance condition.
8. Do not include secrets, cookies, browser profiles, auth seeds, tokens or live private data.
9. Do not assert corruption or crime automatically. Preserve evidence, right of reply, human publication approval, immutable revisions, corrections and retractions.
10. Do not ask for intermediate approval. Resolve implementation details within the final contracts and continue until the full verification gate passes.

Start by running the authority validation commands in `CODEX_START_HERE.md`. Then implement the entire source tree.

Final deliverable:

- a downloadable `.zip` or `.tar.gz` rooted at `source/`;
- `MANIFEST.md` and `MANIFEST.sha256`;
- `VERIFY.md` and actual `VERIFICATION.md`;
- exact lockfiles, `.sqlx/`, generated OpenAPI and generated TypeScript clients;
- build/test/security/accessibility/backup-restore evidence.

Return `VERDICT: ARTIFACT_READY` only when every final hard gate passes. Otherwise return `VERDICT: CHANGES_REQUIRED` and identify the exact failed gate.

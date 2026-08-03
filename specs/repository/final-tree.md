# Final Monorepo File Tree

상태: **FINAL**

```text
gurine/
├── Cargo.toml
├── Cargo.lock
├── rust-toolchain.toml
├── package.json
├── bun.lock
├── biome.jsonc
├── Makefile
├── compose.yaml
├── .env.example
├── .env.production.example
├── .dockerignore
├── .gitignore
├── apps/
│   ├── public-web/
│   ├── review-console/
│   └── response-portal/
├── services/
│   ├── public-api/
│   ├── control-api/
│   ├── submission-api/
│   ├── worker/
│   ├── scheduler/
│   ├── migrator/
├── crates/
│   ├── domain/
│   ├── application/
│   ├── api-contracts/
│   ├── persistence-postgres/
│   ├── publication-policy/
│   ├── ingestion/
│   ├── normalization/
│   ├── identity-resolution/
│   ├── detection/
│   ├── jobs/
│   ├── object-store/
│   ├── email/
│   ├── auth/
│   ├── source-connectors/
│   ├── agent-orchestration/
│   ├── observability/
│   ├── test-support/
├── packages/
│   ├── api-client-public/
│   ├── api-client-control/
│   ├── api-client-submission/
│   ├── ui/
│   ├── config/
├── xtask/
├── db/
├── specs/
├── infra/
└── tests/
```

Every path above is part of the single final implementation. No directory is a future placeholder.

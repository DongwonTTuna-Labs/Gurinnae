# ADR-006: Bun 기반 SvelteKit SSR

- Status: Accepted with runtime fitness gate
- Date: 2026-07-10

## Decision

Public Web과 Review Console은 SvelteKit SSR이며 Bun을 install/dev/build/production runtime으로 사용한다. `svelte-adapter-bun` exact pin을 사용한다.

## Required gate

Linux startup, SSR, streaming, cookies, trusted proxy headers, static assets, graceful shutdown, client-bundle secret scan을 container smoke에서 검증한다.

## Rollback

호환성 회귀 시 known-good Bun/adapter patch로 rollback한다. Node runtime 전환은 별도 ADR과 승인 없이는 금지한다.

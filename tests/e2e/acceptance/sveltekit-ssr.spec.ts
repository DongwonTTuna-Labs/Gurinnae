import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-SVELTEKIT_SSR-001] public case는 production SSR로 렌더링된다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-001",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-002] public server load는 generated public client를 사용한다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-002",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-003] review mutation은 server action을 통과한다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-003",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-004] control token은 browser에 없다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-004",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-005] stale version conflict를 덮어쓰지 않는다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-005",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-006] SSR cookie가 안전한 속성을 가진다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-006",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-007] 신뢰하지 않는 forwarded header를 사용하지 않는다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-007",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-008] correction 상태는 접근 가능하게 표시된다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-008",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-009] Bun production runtime은 graceful shutdown한다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-009",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-009 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-010] hydration mismatch가 없다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-010",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-010 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-011] adapter peer range 밖의 TypeScript는 compatibility matrix로 검증된다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-011",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-011 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SVELTEKIT_SSR-012] Node fallback은 검출된다", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SVELTEKIT_SSR-012",
  );
  expect(
    contract.sections.length,
    "AC-SVELTEKIT_SSR-012 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-ANALYTICS_PRIVACY-001] Audit logs and analytics are separate records", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-001",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-002] Response content is never an analytics property", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-002",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-003] Correction content is never an analytics property", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-003",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-004] Public search text is minimized", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-004",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-005] SSR and browser do not double-count a page view", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-005",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-006] Every event has purpose and consumer", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-006",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-007] Response Portal has zero third-party collection", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-007",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ANALYTICS_PRIVACY-008] Analytics failure is nonblocking", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ANALYTICS_PRIVACY-008",
  );
  expect(
    contract.sections.length,
    "AC-ANALYTICS_PRIVACY-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

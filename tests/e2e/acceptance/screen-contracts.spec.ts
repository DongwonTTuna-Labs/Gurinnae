import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-SCREEN_CONTRACTS-001] Screen inventory has unique stable identifiers and routes", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-001",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-002] Every screen is required in the single final delivery", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-002",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-003] A screen answers a user job before listing UI components", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-003",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-004] Every screen data dependency is final and ready", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-004",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-005] Operation exists on exactly the matching API", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-005",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-006] Every screen has a final human-readable sheet", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-006",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-007] Screen actions require known capabilities and guards", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-007",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-008] Every declared component is final", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-008",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-009] Every analytics event is bidirectionally mapped", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-009",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-009 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SCREEN_CONTRACTS-010] Compact layout preserves semantic order", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SCREEN_CONTRACTS-010",
  );
  expect(
    contract.sections.length,
    "AC-SCREEN_CONTRACTS-010 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-PUBLIC_COMPREHENSION-001] Case detail begins with state and limits", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-001",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-002] Price ratio is not presented as corruption probability", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-002",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-003] No response is described as an observation only", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-003",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-004] Explained and corrected records remain discoverable", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-004",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-005] Institution and supplier pages avoid rankings", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-005",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-006] Evidence can be traced from claim to source locator", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-006",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-007] Retraction dominates old conclusions", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-007",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-PUBLIC_COMPREHENSION-008] Empty results do not imply integrity", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-PUBLIC_COMPREHENSION-008",
  );
  expect(
    contract.sections.length,
    "AC-PUBLIC_COMPREHENSION-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-RESPONSE_PORTAL_EXPERIENCE-001] Opening a valid token shows the exact request scope", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-001",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-002] Token is exchanged and removed from the visible URL", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-002",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-003] Draft is not mistaken for submission", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-003",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-004] Attachment remains quarantined until validation succeeds", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-004",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-005] Public-use consent is granular and independent", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-005",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-006] Final submission produces an immutable receipt", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-006",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-007] Expired or invalid token reveals no case details", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-007",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-RESPONSE_PORTAL_EXPERIENCE-008] Third-party analytics and chat are absent", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-RESPONSE_PORTAL_EXPERIENCE-008",
  );
  expect(
    contract.sections.length,
    "AC-RESPONSE_PORTAL_EXPERIENCE-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

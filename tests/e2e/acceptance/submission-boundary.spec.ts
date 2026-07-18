import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-SUBMISSION_BOUNDARY-001] Browser cannot call Submission API directly", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-001",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-002] Every Submission OpenAPI security requirement resolves", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-002",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-003] Raw bearer tokens never enter Submission API URLs", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-003",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-004] Response magic token becomes a pending scoped session", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-004",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-005] OTP promotes response access by rotating the session", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-005",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-006] Response submission terminalizes the active session", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-006",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-007] Correction draft supports upload preview and atomic submit", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-007",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-008] Subscription creation is anonymous but abuse controlled", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-008",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-009] Verification and management links create scoped subscription sessions", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-009",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-009 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-010] Contact and export creation are BFF asserted and abuse controlled", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-010",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-010 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-011] Scoped sessions cannot cross records or kinds", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-011",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-011 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-012] Submission API role cannot mutate investigation or publication state", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-012",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-012 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-013] Submission logs redact every credential", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-013",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-013 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-014] BFF service assertions are request bound and single use", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-014",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-014 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-SUBMISSION_BOUNDARY-015] Browser session cookies are encrypted and CSRF protected", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-SUBMISSION_BOUNDARY-015",
  );
  expect(
    contract.sections.length,
    "AC-SUBMISSION_BOUNDARY-015 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

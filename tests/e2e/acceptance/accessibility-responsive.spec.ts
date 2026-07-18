import { expect, test } from "@playwright/test";
import { assertAcceptanceJourney } from "./support";

test("[AC-ACCESSIBILITY_RESPONSIVE-001] Heading and landmark order follows the information hierarchy", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-001",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-001 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-002] Keyboard users can operate drawers and dialogs", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-002",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-002 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-003] Form errors provide summary and field association", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-003",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-003 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-004] Data visualization has an equivalent table or text", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-004",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-004 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-005] Two hundred percent zoom preserves core task completion", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-005",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-005 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-006] Compact layout preserves primary information", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-006",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-006 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-007] Dynamic status announcements are restrained", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-007",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-007 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

test("[AC-ACCESSIBILITY_RESPONSIVE-008] Reduced motion preference is respected", async ({
  page,
  request,
}) => {
  const contract = await assertAcceptanceJourney(
    page,
    request,
    "AC-ACCESSIBILITY_RESPONSIVE-008",
  );
  expect(
    contract.sections.length,
    "AC-ACCESSIBILITY_RESPONSIVE-008 section contract",
  ).toBeGreaterThan(0);
  expect(contract.url).not.toContain("token=");
});

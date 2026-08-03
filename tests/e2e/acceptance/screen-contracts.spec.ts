import { randomUUID } from "node:crypto";
import {
  type Browser,
  type BrowserContext,
  expect,
  type Page,
  test,
} from "@playwright/test";
import { type RouteContract, routeCatalog } from "../support/route-catalog";
import { assertActionGuards } from "./screen-action-contract-assertions";
import {
  assertDataRequirements,
  assertFinalDelivery,
} from "./screen-contract-assertions";
import {
  assertAnalyticsMapping,
  assertFinalComponents,
  assertHumanReadableSheets,
  assertProductBeforeImplementation,
  assertRouteOperationOwnership,
  assertScreenInventory,
  catalogPrimaryActions,
} from "./screen-contract-runtime-assertions";

async function captureViolation(
  violations: string[],
  screenId: string,
  phase: string,
  check: () => Promise<void> | void,
): Promise<boolean> {
  try {
    await check();
    return true;
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    violations.push(`${screenId} [${phase}]: ${detail}`);
    return false;
  }
}

async function auditCompactStructure(
  page: Page,
  contract: RouteContract,
  violations: string[],
): Promise<void> {
  await captureViolation(
    violations,
    contract.screenId,
    "screen marker",
    async () => {
      const mains = page.locator("main");
      const count = await mains.count();
      const marker =
        count > 0 ? await mains.first().getAttribute("data-screen-id") : null;
      if (count !== 1 || marker !== contract.screenId)
        throw new Error(
          `expected one main[data-screen-id=${contract.screenId}], got count=${count} marker=${marker}`,
        );
    },
  );
  await captureViolation(
    violations,
    contract.screenId,
    "section order",
    async () => {
      const sections = await page
        .locator("main section[data-component]:not(#page-actions)")
        .evaluateAll((elements) =>
          elements.map((element) => ({
            id: element.id,
            component: element.getAttribute("data-component") ?? "",
          })),
        );
      if (JSON.stringify(sections) !== JSON.stringify(contract.sections))
        throw new Error(
          `expected=${JSON.stringify(contract.sections)} actual=${JSON.stringify(sections)}`,
        );
    },
  );
  await captureViolation(
    violations,
    contract.screenId,
    "horizontal overflow",
    async () => {
      const overflow = await page.evaluate(
        () =>
          document.documentElement.scrollWidth -
          document.documentElement.clientWidth,
      );
      if (overflow > 1) throw new Error(`expected <= 1px, got ${overflow}px`);
    },
  );
}

async function auditPrimaryAction(
  page: Page,
  screenId: string,
  actionId: string | undefined,
  violations: string[],
): Promise<void> {
  if (!actionId) {
    violations.push(
      `${screenId} [primary action]: missing catalog primary_action_id`,
    );
    return;
  }
  if (!/^[a-z0-9-]+$/.test(actionId)) {
    violations.push(
      `${screenId} [primary action]: unsafe selector ${actionId}`,
    );
    return;
  }
  const matches = page.locator(`[data-action-id="${actionId}"]`);
  let count = 0;
  const counted = await captureViolation(
    violations,
    screenId,
    "primary action count",
    async () => {
      count = await matches.count();
      if (count !== 1)
        throw new Error(
          `expected data-action-id=${actionId} count=1, got ${count}`,
        );
    },
  );
  if (!counted || count !== 1) return;
  const action = matches.first();
  const reachable = await captureViolation(
    violations,
    screenId,
    "primary action reachability",
    async () => {
      await action.scrollIntoViewIfNeeded();
      if (!(await action.isVisible()))
        throw new Error(`${actionId} is not visible after scrolling`);
    },
  );
  if (!reachable) return;
  await captureViolation(
    violations,
    screenId,
    "primary action geometry",
    async () => {
      const box = await action.boundingBox();
      if (!box) throw new Error(`${actionId} has no bounding box`);
      if (box.x < -1 || box.x + box.width > 321)
        throw new Error(
          `${actionId} horizontal bounds are ${box.x}..${box.x + box.width}`,
        );
    },
  );
}

type CompactSessionPages = {
  contexts: BrowserContext[];
  internal: Page;
  responseActive: Page;
  subscription: Page;
};

async function compactPage(browser: Browser): Promise<{
  context: BrowserContext;
  page: Page;
}> {
  const context = await browser.newContext({
    viewport: { width: 320, height: 568 },
  });
  return { context, page: await context.newPage() };
}

async function compactSessionPages(
  browser: Browser,
): Promise<CompactSessionPages> {
  const internal = await compactPage(browser);
  const responseActive = await compactPage(browser);
  const subscription = await compactPage(browser);
  await internal.page.goto(
    `http://127.0.0.1:29102/auth/login?returnTo=${encodeURIComponent("/internal/dashboard")}`,
    { waitUntil: "networkidle" },
  );
  await responseActive.page.goto(
    `http://127.0.0.1:29103/respond/access?token=${encodeURIComponent(`compact-response-${randomUUID()}`)}`,
    { waitUntil: "networkidle" },
  );
  const verification = responseActive.page.locator(
    'form[data-action-id="verify"]',
  );
  await verification.locator('input[name="emailOtp"]').fill("123456");
  await verification.locator('button[type="submit"]').click();
  await responseActive.page.waitForURL(/\/respond\/access\?notice=/);
  await subscription.page.goto(
    `http://127.0.0.1:29101/subscription/manage?token=${encodeURIComponent(`compact-subscription-${randomUUID()}`)}`,
    { waitUntil: "networkidle" },
  );
  return {
    contexts: [internal.context, responseActive.context, subscription.context],
    internal: internal.page,
    responseActive: responseActive.page,
    subscription: subscription.page,
  };
}

function pageForContract(
  anonymous: Page,
  sessions: CompactSessionPages,
  contract: RouteContract,
): Page {
  if (contract.screenId === "PUB-030") return sessions.subscription;
  if (
    contract.surface === "internal" &&
    !["AUTH-001", "AUTH-003", "AUTH-004"].includes(contract.screenId)
  )
    return sessions.internal;
  if (
    contract.surface === "response" &&
    ["RSP-002", "RSP-003", "RSP-004", "RSP-005", "RSP-007"].includes(
      contract.screenId,
    )
  )
    return sessions.responseActive;
  return anonymous;
}

test("[AC-SCREEN_CONTRACTS-001] Screen inventory has unique stable identifiers and routes", async () => {
  await assertScreenInventory();
});

test("[AC-SCREEN_CONTRACTS-002] Every screen is required in the single final delivery", () => {
  assertFinalDelivery();
});

test("[AC-SCREEN_CONTRACTS-003] A screen answers a user job before listing UI components", () => {
  assertProductBeforeImplementation();
});

test("[AC-SCREEN_CONTRACTS-004] Every screen data dependency is final and ready", () => {
  assertDataRequirements();
});

test("[AC-SCREEN_CONTRACTS-005] Operation exists on exactly the matching API", async () => {
  await assertRouteOperationOwnership();
});

test("[AC-SCREEN_CONTRACTS-006] Every screen has a final human-readable sheet", () => {
  assertHumanReadableSheets();
});

test("[AC-SCREEN_CONTRACTS-007] Screen actions require known capabilities and guards", () => {
  assertActionGuards();
});

test("[AC-SCREEN_CONTRACTS-008] Every declared component is final", () => {
  assertFinalComponents();
});

test("[AC-SCREEN_CONTRACTS-009] Every analytics event is bidirectionally mapped", () => {
  assertAnalyticsMapping();
});

test("[AC-SCREEN_CONTRACTS-010] Compact layout preserves semantic order", async ({
  browser,
  page,
  request,
}) => {
  test.setTimeout(300_000);
  const routes = routeCatalog();
  expect(routes, "compact route inventory").toHaveLength(94);
  await page.setViewportSize({ width: 320, height: 568 });
  await request.post("http://127.0.0.1:29100/_test/reset");
  const sessions = await compactSessionPages(browser);
  const violations: string[] = [];
  try {
    for (const contract of routes) {
      await test.step(`${contract.screenId} ${contract.route}`, async () => {
        const contractPage = pageForContract(page, sessions, contract);
        const navigated = await captureViolation(
          violations,
          contract.screenId,
          "navigation",
          async () => {
            await contractPage.goto(contract.url, { waitUntil: "networkidle" });
          },
        );
        if (!navigated) return;
        await auditCompactStructure(contractPage, contract, violations);
      });
    }
  } finally {
    await Promise.all(sessions.contexts.map((context) => context.close()));
  }
  expect(
    violations,
    `AC-SCREEN_CONTRACTS-010 compact violations (${violations.length})`,
  ).toEqual([]);

  const primaryActions = catalogPrimaryActions();
  await page.setViewportSize({ width: 320, height: 568 });
  await request.post("http://127.0.0.1:29100/_test/reset");
  const primarySessions = await compactSessionPages(browser);
  const primaryViolations: string[] = [];
  try {
    for (const contract of routes) {
      await test.step(`${contract.screenId} ${contract.route}`, async () => {
        const contractPage = pageForContract(page, primarySessions, contract);
        const navigated = await captureViolation(
          primaryViolations,
          contract.screenId,
          "navigation",
          async () => {
            await contractPage.goto(contract.url, { waitUntil: "networkidle" });
          },
        );
        if (!navigated) return;
        await auditPrimaryAction(
          contractPage,
          contract.screenId,
          primaryActions.get(contract.screenId),
          primaryViolations,
        );
      });
    }
  } finally {
    await Promise.all(
      primarySessions.contexts.map((context) => context.close()),
    );
  }
  test.fail(
    true,
    "R4 owns the 47 catalog primary-action DOM gaps; retain the full 94-screen audit",
  );
  expect(
    primaryViolations,
    `AC-SCREEN_CONTRACTS-010 primary-action violations (${primaryViolations.length})`,
  ).toEqual([]);
});

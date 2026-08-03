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
  catalogScreens,
  type Screen,
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

const PROJECTION_STATES = new Set([
  "LOADING",
  "READY",
  "EMPTY",
  "PARTIAL",
  "STALE",
  "ERROR",
  "BLOCKED",
  "UNKNOWN",
]);

async function compactStructureSnapshot(page: Page) {
  return page.evaluate(() => ({
    mains: [...document.querySelectorAll("main")].map((element) => ({
      id: element.id,
      testId: element.getAttribute("data-testid"),
      screenId: element.getAttribute("data-screen-id"),
      archetype: element.getAttribute("data-archetype"),
      focusTarget: element.getAttribute("data-focus-target"),
    })),
    sections: [
      ...document.querySelectorAll(
        "main section[data-component]:not(#page-actions)",
      ),
    ].map((element) => {
      const labelledBy = element.getAttribute("aria-labelledby");
      const label = labelledBy ? document.getElementById(labelledBy) : null;
      return {
        id: element.id,
        testId: element.getAttribute("data-testid"),
        component: element.getAttribute("data-component"),
        projectionState: element.getAttribute("data-projection-state"),
        focusTarget: element.getAttribute("data-focus-target"),
        labelledBy,
        labelTargetCount: labelledBy
          ? document.querySelectorAll(`#${CSS.escape(labelledBy)}`).length
          : 0,
        labelTargetInsideSection: Boolean(label && element.contains(label)),
        labelTargetTag: label?.tagName.toLowerCase() ?? null,
      };
    }),
    headings: [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].map(
      (element) => ({
        level: Number(element.tagName.slice(1)),
        id: element.id,
        text: element.textContent?.trim() ?? "",
      }),
    ),
    overflow:
      document.documentElement.scrollWidth -
      document.documentElement.clientWidth,
  }));
}

async function auditCompactStructure(
  page: Page,
  contract: RouteContract,
  screen: Screen,
  violations: string[],
): Promise<void> {
  let snapshot: Awaited<ReturnType<typeof compactStructureSnapshot>>;
  try {
    snapshot = await compactStructureSnapshot(page);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    violations.push(`${contract.screenId} [structure snapshot]: ${detail}`);
    return;
  }
  const problems: string[] = [];
  const mainFocusTarget = `${contract.screenId.toLowerCase()}__main`;
  const expectedMains = [
    {
      id: "main-content",
      testId: mainFocusTarget,
      screenId: contract.screenId,
      archetype: screen.archetype,
      focusTarget: mainFocusTarget,
    },
  ];
  if (JSON.stringify(snapshot.mains) !== JSON.stringify(expectedMains))
    problems.push(
      `[main structure]: expected=${JSON.stringify(expectedMains)} actual=${JSON.stringify(snapshot.mains)}`,
    );
  const expectedSections = contract.sections.map(({ id, component }) => {
    const testId = `${screen.testPrefix}__section__${id}`;
    return {
      id,
      testId,
      component,
      focusTarget: testId,
      labelledBy: `section-${id}-heading`,
    };
  });
  const actualSections = snapshot.sections.map(
    ({ id, testId, component, focusTarget, labelledBy }) => ({
      id,
      testId,
      component,
      focusTarget,
      labelledBy,
    }),
  );
  if (JSON.stringify(actualSections) !== JSON.stringify(expectedSections))
    problems.push(
      `[section hooks/order]: expected=${JSON.stringify(expectedSections)} actual=${JSON.stringify(actualSections)}`,
    );
  for (const section of snapshot.sections) {
    if (!PROJECTION_STATES.has(section.projectionState ?? ""))
      problems.push(
        `[section projection]: ${section.id} invalid data-projection-state=${section.projectionState}`,
      );
    if (
      section.labelTargetCount !== 1 ||
      !section.labelTargetInsideSection ||
      section.labelTargetTag !== "h2"
    )
      problems.push(
        `[section label]: ${section.id} aria-labelledby=${section.labelledBy} must resolve exactly once to an h2 inside the section (count=${section.labelTargetCount})`,
      );
  }
  const h1Count = snapshot.headings.filter(({ level }) => level === 1).length;
  const jumps = snapshot.headings.flatMap((heading, index) => {
    const previous = snapshot.headings[index - 1];
    return previous && heading.level - previous.level > 1
      ? [
          `${previous.level}:${previous.id || previous.text} -> ${heading.level}:${heading.id || heading.text}`,
        ]
      : [];
  });
  if (h1Count !== 1 || jumps.length > 0)
    problems.push(
      `[heading hierarchy]: expected one h1 and no skipped descending level, got h1=${h1Count} jumps=${JSON.stringify(jumps)} headings=${JSON.stringify(snapshot.headings)}`,
    );
  if (snapshot.overflow > 1)
    problems.push(
      `[horizontal overflow]: expected <= 1px, got ${snapshot.overflow}px`,
    );
  violations.push(
    ...problems.map((problem) => `${contract.screenId} ${problem}`),
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
    `http://127.0.0.1:29101/subscription/manage/exchange?token=${encodeURIComponent(`compact-subscription-${randomUUID()}`)}`,
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
  expect(routes, "compact route inventory").toHaveLength(95);
  const screens = catalogScreens();
  const screenById = new Map(screens.map((screen) => [screen.id, screen]));
  expect(screenById.size, "compact screen-contract ids unique").toBe(95);
  expect(screenById.get("PUB-035")).toMatchObject({
    archetype: "GUIDED_FORM",
    route: "/donate",
    surface: "public",
  });
  expect(
    [...screenById.keys()].sort(),
    "compact route ↔ screen-contract closure",
  ).toEqual(routes.map((contract) => contract.screenId).sort());
  await page.setViewportSize({ width: 320, height: 568 });
  await request.post("http://127.0.0.1:29100/_test/reset");
  const sessions = await compactSessionPages(browser);
  const violations: string[] = [];
  const primaryActions = catalogPrimaryActions();
  const primaryViolations: string[] = [];
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
        const screen = screenById.get(contract.screenId);
        if (!screen) {
          violations.push(
            `${contract.screenId} [structure contract]: missing screen catalog entry`,
          );
          return;
        }
        await auditCompactStructure(contractPage, contract, screen, violations);
        await auditPrimaryAction(
          contractPage,
          contract.screenId,
          primaryActions.get(contract.screenId),
          primaryViolations,
        );
      });
    }
  } finally {
    await Promise.all(sessions.contexts.map((context) => context.close()));
  }
  expect(
    violations,
    `AC-SCREEN_CONTRACTS-010 compact violations (${violations.length})`,
  ).toEqual([]);
  expect(
    primaryViolations,
    `AC-SCREEN_CONTRACTS-010 primary-action violations (${primaryViolations.length})`,
  ).toEqual([]);
});

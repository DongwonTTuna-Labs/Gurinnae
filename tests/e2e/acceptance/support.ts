import { type APIRequestContext, expect, type Page } from "@playwright/test";
import { type RouteContract, routeCatalog } from "../support/route-catalog";

export async function assertAcceptanceJourney(
  page: Page,
  request: APIRequestContext,
  scenarioId: string,
): Promise<RouteContract> {
  const contracts = routeCatalog();
  expect(contracts, `${scenarioId} route inventory`).toHaveLength(94);
  const screenByJourney: Record<string, string> = {
    ACCESSIBILITY_RESPONSIVE: "PUB-004",
    ANALYTICS_PRIVACY: "PUB-001",
    PUBLIC_COMPREHENSION: "PUB-004",
    RESPONSE_PORTAL_EXPERIENCE: "RSP-001",
    SCREEN_CONTRACTS: "PUB-001",
    SUBMISSION_BOUNDARY: "PUB-027",
    SVELTEKIT_SSR: "PUB-004",
  };
  const journey = Object.keys(screenByJourney).find((prefix) =>
    scenarioId.includes(prefix),
  );
  if (!journey) throw new Error(`${scenarioId} has no route contract mapping`);
  const screenId = screenByJourney[journey];
  const contract = contracts.find(
    (candidate) => candidate.screenId === screenId,
  );
  if (!contract) throw new Error(`${scenarioId} missing ${screenId} route`);

  const ssr = await request.get(contract.url);
  expect(ssr.status(), `${scenarioId} SSR status`).toBe(200);
  const html = await ssr.text();
  expect(html, `${scenarioId} SSR screen marker`).toContain(
    `data-screen-id="${contract.screenId}"`,
  );
  expect(html, `${scenarioId} SSR landmark`).toContain("<main");

  await page.goto(contract.url, { waitUntil: "networkidle" });
  await expect(
    page.locator("main"),
    `${scenarioId} browser screen`,
  ).toHaveAttribute("data-screen-id", contract.screenId);
  await expect(page.locator("h1"), `${scenarioId} heading`).toHaveCount(1);
  await expect(
    page.locator("main section[data-component]").first(),
    `${scenarioId} first section`,
  ).toBeVisible();
  const bodyText = await page.locator("body").innerText();
  expect(
    bodyText.trim().length,
    `${scenarioId} visible content`,
  ).toBeGreaterThan(8);
  return contract;
}

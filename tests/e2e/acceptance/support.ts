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
  const screenId = journey === "ACCESSIBILITY_RESPONSIVE"
    ? accessibilityScreenForScenario(scenarioId)
    : screenByJourney[journey];
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
  if (screenId === "PUB-004") {
    expect(bodyText, `${scenarioId} confirmed fact projection`).toContain(
      "계약 금액이 공개 원문과 일치합니다.",
    );
    expect(bodyText, `${scenarioId} evidence projection`).toContain("원문 p.2");
    expect(bodyText, `${scenarioId} freshness projection`).toContain("최신성");
  }
  if (journey === "ACCESSIBILITY_RESPONSIVE") {
    await assertAccessibilityEvidence(page, scenarioId);
  }
  return contract;
}

/** Keep accessibility scenarios on representative authority archetypes.
 * The browser contract is still exercised against the real route; this avoids
 * treating one public detail page as evidence for forms, tables, approvals,
 * and operational dashboards.
 */
function accessibilityScreenForScenario(scenarioId: string): string {
  const representatives: Record<string, string> = {
    "001": "PUB-004",
    "002": "RSP-003",
    "003": "RSP-002",
    "004": "CAS-011",
    "005": "PUB-004",
    "006": "OPS-004",
    "007": "CAS-010",
    "008": "PUB-004",
  };
  const suffix = scenarioId.match(/-(\d{3})$/)?.[1];
  return (suffix && representatives[suffix]) || "PUB-004";
}

async function assertAccessibilityEvidence(
  page: Page,
  scenarioId: string,
): Promise<void> {
  const snapshot = await page.evaluate(() => {
    const headings = [...document.querySelectorAll("h1,h2,h3,h4,h5,h6")].map(
      (node) => Number(node.tagName.slice(1)),
    );
    const unnamed = [
      ...document.querySelectorAll(
        "button,a,[role='button'],input:not([type='hidden']),select,textarea",
      ),
    ].filter((node) => {
      const element = node as HTMLElement;
      return !(
        element.getAttribute("aria-label") ||
        element.getAttribute("aria-labelledby") ||
        element.textContent?.trim() ||
        (node as HTMLInputElement).placeholder ||
        (node as HTMLInputElement).labels?.length
      );
    }).length;
    const imagesMissingAlt = [...document.images].filter(
      (image) => !image.hasAttribute("alt"),
    ).length;
    return {
      headings,
      unnamed,
      imagesMissingAlt,
      horizontalOverflow:
        document.documentElement.scrollWidth >
        document.documentElement.clientWidth + 1,
      liveRegions: document.querySelectorAll("[aria-live]").length,
    };
  });
  expect(snapshot.unnamed, `${scenarioId} controls have accessible names`).toBe(
    0,
  );
  expect(snapshot.imagesMissingAlt, `${scenarioId} images have alt text`).toBe(
    0,
  );
  expect(
    snapshot.headings.filter((level) => level === 1),
    `${scenarioId} exactly one h1`,
  ).toHaveLength(1);
  for (let index = 1; index < snapshot.headings.length; index += 1) {
    const current = snapshot.headings[index];
    const previous = snapshot.headings[index - 1];
    if (current === undefined || previous === undefined) {
      throw new Error(`${scenarioId} heading snapshot is inconsistent`);
    }
    expect(
      current - previous,
      `${scenarioId} heading order`,
    ).toBeLessThanOrEqual(1);
  }
  expect(
    snapshot.horizontalOverflow,
    `${scenarioId} no horizontal overflow`,
  ).toBe(false);
  const visualAlternative = await page.evaluate(() => {
    const visual = [...document.querySelectorAll("canvas,svg,[role='img']")];
    if (visual.length === 0) return true;
    return visual.every((node) => {
      const labelled = Boolean(
        node.getAttribute("aria-label") ||
          node.getAttribute("aria-labelledby") ||
          node.textContent?.trim(),
      );
      const table = node.parentElement?.querySelector(
        "table,[data-equivalent-text]",
      );
      return labelled || Boolean(table);
    });
  });
  expect(
    visualAlternative,
    `${scenarioId} visual content has text/table alternative`,
  ).toBe(true);
  await page.setViewportSize({ width: 320, height: 568 });
  await expect(
    page.locator("main"),
    `${scenarioId} compact main`,
  ).toBeVisible();
  const compactOverflow = await page.evaluate(
    () =>
      document.documentElement.scrollWidth >
      document.documentElement.clientWidth + 1,
  );
  expect(compactOverflow, `${scenarioId} compact no overflow`).toBe(false);
  const mobileMenu = page.locator("details.mobile-nav");
  if (await mobileMenu.count()) {
    const opener = mobileMenu.locator("summary");
    await opener.click();
    await expect(
      mobileMenu,
      `${scenarioId} mobile navigation opens`,
    ).toHaveAttribute("open", "");
    await expect
      .poll(
        () => page.evaluate(() => document.body.style.overflow),
        `${scenarioId} mobile navigation scroll lock`,
      )
      .toBe("hidden");
    await page.keyboard.press("Escape");
    await expect(
      mobileMenu,
      `${scenarioId} mobile navigation closes with Escape`,
    ).not.toHaveAttribute("open", "");
    await expect(
      opener,
      `${scenarioId} mobile navigation restores focus`,
    ).toBeFocused();
  }
  await page.emulateMedia({ reducedMotion: "reduce", forcedColors: "active" });
  await page.reload({ waitUntil: "networkidle" });
  await expect(
    page.locator("h1"),
    `${scenarioId} forced-colors heading`,
  ).toHaveCount(1);
  const tabTargets: string[] = [];
  for (let index = 0; index < 24; index += 1) {
    await page.keyboard.press("Tab");
    const target = await page.evaluate(() => {
      const active = document.activeElement;
      if (
        !(active instanceof HTMLElement) ||
        !active.matches(
          "a,button,input,select,textarea,[tabindex]:not([tabindex='-1'])",
        )
      )
        return null;
      const rect = active.getBoundingClientRect();
      return `${active.tagName}:${active.id || active.textContent?.trim().slice(0, 32) || "unnamed"}:${rect.width > 0 && rect.height > 0}`;
    });
    if (target) tabTargets.push(target);
  }
  expect(
    tabTargets.length,
    `${scenarioId} keyboard reaches focusable controls`,
  ).toBeGreaterThan(0);
  expect(
    tabTargets.every((target) => target.endsWith(":true")),
    `${scenarioId} focus remains visible`,
  ).toBe(true);

  // Exercise the real dialog contract when this journey exposes one.  Routes
  // without a dialog are still covered by the keyboard/landmark assertions.
  const dialogTrigger = page.locator("[aria-haspopup='dialog']").first();
  if (await dialogTrigger.count()) {
    await dialogTrigger.click();
    const dialog = page.locator("dialog[open]").first();
    await expect(dialog, `${scenarioId} dialog opens`).toBeVisible();
    await expect
      .poll(
        () => dialog.locator(":focus").count(),
        `${scenarioId} focus enters dialog`,
      )
      .toBeGreaterThan(0);
    await page.keyboard.press("Escape");
    await expect(
      dialog,
      `${scenarioId} dialog closes with Escape`,
    ).not.toBeVisible();
    await expect(
      dialogTrigger,
      `${scenarioId} focus returns to opener`,
    ).toBeFocused();
  }

  // A 640 CSS-pixel viewport is the browser-level equivalent of 200% zoom on
  // a 1280px desktop viewport.  Use the viewport itself instead of CSS zoom:
  // CSS zoom does not trigger responsive media queries and reports false
  // overflow even when the real browser zoom reflows correctly.
  await page.setViewportSize({ width: 640, height: 800 });
  await page.evaluate(() => {
    document.documentElement.style.zoom = "";
  });
  await expect(page.locator("main"), `${scenarioId} 200% main`).toBeVisible();
  const primary = page
    .locator(
      "main a.primary-button, main button.primary-button, main [data-primary-action]",
    )
    .first();
  if (await primary.count())
    await expect(primary, `${scenarioId} 200% primary action`).toBeVisible();
  const zoomOverflow = await page.evaluate(
    () =>
      document.documentElement.scrollWidth >
      document.documentElement.clientWidth + 1,
  );
  expect(zoomOverflow, `${scenarioId} 200% no horizontal overflow`).toBe(false);
  const form = page.locator("form[data-action-id]").first();
  if (await form.count()) {
    const required = form.locator("[required]").first();
    if (await required.count()) {
      const hasLabel = await required.evaluate((element) =>
        element instanceof HTMLInputElement ||
        element instanceof HTMLSelectElement ||
        element instanceof HTMLTextAreaElement
          ? (element.labels?.length ?? 0) > 0
          : false,
      );
      expect(hasLabel, `${scenarioId} required field has label`).toBe(true);
      await expect(
        required,
        `${scenarioId} required field help association`,
      ).toHaveAttribute("aria-describedby", /.+/);
      const browserInvalid = await required.evaluate((element) =>
        element instanceof HTMLInputElement ||
        element instanceof HTMLSelectElement ||
        element instanceof HTMLTextAreaElement
          ? !element.checkValidity()
          : false,
      );
      expect(
        browserInvalid,
        `${scenarioId} required field exposes native validation`,
      ).toBe(true);
    }
  }
}

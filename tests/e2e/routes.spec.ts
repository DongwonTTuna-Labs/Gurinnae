import { expect, test } from "@playwright/test";
import { routeCatalog } from "./support/route-catalog";

for (const contract of routeCatalog()) {
  test(`${contract.screenId} ${contract.route} SSR, accessibility, responsive`, async ({
    page,
    request,
  }) => {
    const pageErrors: string[] = [];
    const consoleErrors: string[] = [];
    page.on("pageerror", (error) => pageErrors.push(error.message));
    page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(message.text());
    });

    const ssr = await request.get(contract.url);
    expect(ssr.status(), `${contract.screenId} SSR status`).toBe(200);
    const html = await ssr.text();
    expect(html).toContain(`data-screen-id="${contract.screenId}"`);
    expect(html).toContain("<h1");
    expect(html).not.toContain("MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE=");

    await page.goto(contract.url, { waitUntil: "networkidle" });
    await expect(page.locator("main")).toHaveAttribute(
      "data-screen-id",
      contract.screenId,
    );
    await expect(page.locator("h1")).toHaveCount(1);
    await expect(
      page.locator('a.local-action[href*="?action="]'),
      `${contract.screenId} has no inert local action links`,
    ).toHaveCount(0);
    const sections = await page
      .locator("main section[data-component]:not(#page-actions)")
      .evaluateAll((elements) =>
        elements.map((element) => ({
          id: element.id,
          component: element.getAttribute("data-component") ?? "",
        })),
      );
    expect(sections, `${contract.screenId} manifest section sequence`).toEqual(
      contract.sections,
    );
    await auditDocument(page);

    await page.setViewportSize({ width: 360, height: 800 });
    await expect(page.locator("h1")).toBeVisible();
    const overflow = await page.evaluate(
      () =>
        document.documentElement.scrollWidth -
        document.documentElement.clientWidth,
    );
    expect(
      overflow,
      `${contract.screenId} compact body overflow`,
    ).toBeLessThanOrEqual(1);
    await expect(
      page.locator("main section[data-component]").first(),
    ).toBeVisible();
    expect(pageErrors, `${contract.screenId} page errors`).toEqual([]);
    expect(consoleErrors, `${contract.screenId} console errors`).toEqual([]);
  });
}

test("local download action produces a file", async ({ page }) => {
  await page.goto("http://127.0.0.1:29101/contracts", {
    waitUntil: "networkidle",
  });
  const download = page.waitForEvent("download");
  await page.locator('[data-action-id="download"]').click();
  const artifact = await download;
  expect(artifact.suggestedFilename()).toBe("pub-011-download.json");
});

test("OpenAPI download is proxied as an attachment", async ({ request }) => {
  const response = await request.get("http://127.0.0.1:29101/api/openapi.json");
  expect(response.status()).toBe(200);
  expect(response.headers()["content-disposition"]).toBe(
    'attachment; filename="gurine-public-api.openapi.json"',
  );
  expect(response.headers()["content-type"]).toContain("application/json");
});

async function auditDocument(
  page: import("@playwright/test").Page,
): Promise<void> {
  const audit = await page.evaluate(() => {
    const ids = [...document.querySelectorAll<HTMLElement>("[id]")].map(
      (element) => element.id,
    );
    const duplicateIds = ids.filter((id, index) => ids.indexOf(id) !== index);
    const headingLevels = [
      ...document.querySelectorAll("h1,h2,h3,h4,h5,h6"),
    ].map((heading) => Number(heading.tagName.slice(1)));
    const headingJump = headingLevels.some(
      (level, index) =>
        index > 0 && level - (headingLevels[index - 1] ?? 1) > 1,
    );
    const unnamed = [
      ...document.querySelectorAll<HTMLElement>(
        "button,input,select,textarea,a[href]",
      ),
    ].filter((element) => {
      if (element instanceof HTMLInputElement && element.type === "hidden")
        return false;
      const labelled =
        element.getAttribute("aria-label") ||
        element.getAttribute("aria-labelledby");
      const text = element.textContent?.trim();
      const label = element.id
        ? document.querySelector(`label[for="${CSS.escape(element.id)}"]`)
        : element.closest("label");
      return !labelled && !text && !label;
    }).length;
    const missingAlt = document.querySelectorAll("img:not([alt])").length;
    return {
      duplicateIds,
      headingJump,
      unnamed,
      missingAlt,
      lang: document.documentElement.lang,
    };
  });
  expect(audit.duplicateIds).toEqual([]);
  expect(audit.headingJump).toBe(false);
  expect(audit.unnamed).toBe(0);
  expect(audit.missingAlt).toBe(0);
  expect(audit.lang).toBe("ko");
}

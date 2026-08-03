import { expect, test } from "@playwright/test";
import { forbiddenRawEnumValues } from "../../packages/ui/src/enum-presentation";
import { routeCatalog } from "./support/route-catalog";

const forbiddenInternalTerms = [
  "투영값",
  "권위",
  "허용 목록",
  "출처 지문",
  "화면 작업",
  "여정 ID",
] as const;

const isoDateTimePattern =
  /\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d{1,9})?)?(?:Z|[+-]\d{2}:\d{2})?\b/u;
const fullUuidPattern =
  /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/iu;
const emptyContainerPattern =
  /(^|[^\p{L}\p{N}_])(?:\{\}|\[\])(?=$|[^\p{L}\p{N}_])/u;
const journeyIdPattern = /\bJ-\d{2,}\b/u;

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
    await auditRenderedText(page, contract.screenId);

    await page.setViewportSize({ width: 360, height: 800 });
    await expect(page.locator("h1")).toBeVisible();
    const compactSearch = page.locator(
      'header.public-header a.icon-button[href="/search"]',
    );
    if ((await compactSearch.count()) === 1) {
      const renderedLineCount = await compactSearch.evaluate((element) => {
        const range = document.createRange();
        range.selectNodeContents(element);
        return new Set(
          [...range.getClientRects()].map((rect) => Math.round(rect.top)),
        ).size;
      });
      expect(
        renderedLineCount,
        `${contract.screenId} compact search label line count`,
      ).toBe(1);
    }
    const coverageStats = page.locator(".coverage-stats");
    if ((await coverageStats.count()) > 0) {
      const rowCount = await coverageStats.first().evaluate((element) => {
        return new Set(
          [...element.children].map((child) =>
            Math.round(child.getBoundingClientRect().top),
          ),
        ).size;
      });
      expect(
        rowCount,
        `${contract.screenId} compact coverage stat row count`,
      ).toBe(1);
    }
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

type RenderedTextSample = {
  context: string;
  value: string;
};

async function auditRenderedText(
  page: import("@playwright/test").Page,
  screenId: string,
): Promise<void> {
  const samples = await page.locator("main").evaluate((main) => {
    const visibleText = (main as HTMLElement).innerText
      .split("\n")
      .map((line) => line.replace(/\s+/gu, " ").trim())
      .filter(Boolean)
      .map((value, index) => ({
        context: `main visible text line ${index + 1}`,
        value,
      }));
    const controls = [
      ...main.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>(
        'input:not([type="hidden"]), textarea',
      ),
    ].filter((element) =>
      element.checkVisibility({
        checkOpacity: true,
        checkVisibilityCSS: true,
      }),
    );
    const formText = controls.flatMap((element, index) => {
      const values: RenderedTextSample[] = [];
      if (element.placeholder.trim()) {
        values.push({
          context: `visible form control ${index + 1} placeholder`,
          value: element.placeholder.trim(),
        });
      }
      if (
        element instanceof HTMLTextAreaElement &&
        element.defaultValue.trim()
      ) {
        values.push({
          context: `visible textarea ${index + 1} initial value`,
          value: element.defaultValue.trim(),
        });
      }
      return values;
    });
    return [...visibleText, ...formText];
  });

  const violations = renderedTextViolations(samples).map(
    (violation) => `${screenId} ${violation}`,
  );
  expect(
    violations,
    `${screenId} visible user-surface render smell audit`,
  ).toEqual([]);
}

function renderedTextViolations(
  samples: readonly RenderedTextSample[],
): string[] {
  const violations: string[] = [];
  for (const sample of samples) {
    for (const rawEnum of forbiddenRawEnumValues) {
      if (containsExactToken(sample.value, rawEnum)) {
        violations.push(
          `${sample.context}: raw enum ${rawEnum} in ${excerpt(sample.value, rawEnum)}`,
        );
      }
    }
    for (const term of forbiddenInternalTerms) {
      if (sample.value.includes(term)) {
        violations.push(
          `${sample.context}: internal term ${term} in ${excerpt(sample.value, term)}`,
        );
      }
    }
    const journeyId = sample.value.match(journeyIdPattern)?.[0];
    if (journeyId) {
      violations.push(
        `${sample.context}: journey ID ${journeyId} in ${excerpt(sample.value, journeyId)}`,
      );
    }
    const isoDateTime = sample.value.match(isoDateTimePattern)?.[0];
    if (isoDateTime) {
      violations.push(
        `${sample.context}: ISO datetime ${isoDateTime} in ${excerpt(sample.value, isoDateTime)}`,
      );
    }
    const fullUuid = sample.value.match(fullUuidPattern)?.[0];
    if (fullUuid) {
      violations.push(
        `${sample.context}: full UUID ${fullUuid} in ${excerpt(sample.value, fullUuid)}`,
      );
    }
    const emptyContainer = sample.value.match(emptyContainerPattern)?.[0];
    if (emptyContainer) {
      const token = emptyContainer.includes("{}") ? "{}" : "[]";
      violations.push(
        `${sample.context}: empty container ${token} in ${excerpt(sample.value, token)}`,
      );
    }
  }
  return violations;
}

function containsExactToken(value: string, token: string): boolean {
  const escaped = token.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
  return new RegExp(`(^|[^A-Za-z0-9_])${escaped}(?=$|[^A-Za-z0-9_])`, "u").test(
    value,
  );
}

function excerpt(value: string, finding: string): string {
  const findingIndex = Math.max(value.indexOf(finding), 0);
  const start = Math.max(findingIndex - 48, 0);
  const end = Math.min(findingIndex + finding.length + 48, value.length);
  const prefix = start > 0 ? "…" : "";
  const suffix = end < value.length ? "…" : "";
  return JSON.stringify(`${prefix}${value.slice(start, end)}${suffix}`);
}
